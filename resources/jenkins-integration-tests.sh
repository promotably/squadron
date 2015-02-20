#!/bin/bash

: ${KEY_BUCKET:=promotably-keyvault}

# helper function to wait for stack creation/update
get_stack_status() {
    set +x
    timeout_ts=$((`date +%s` + 1800))
    while [ $(date +%s) -le $timeout_ts ] && sleep 20; do
        stack_status=$(aws cloudformation describe-stacks --output=text --stack-name "$1" --query 'Stacks[0].StackStatus')
        if [ "$2" = 'update' ]; then
            case "$stack_status" in 
                UPDATE_COMPLETE)
                    echo $stack_status
                    return 0
                    ;;
                UPDATE_ROLLBACK_COMPLETE|UPDATE_ROLLBACK_FAILED)
                    echo $stack_status
                    return 1
                    ;;
            esac
        else
            case "$stack_status" in 
                CREATE_COMPLETE)
                    echo $stack_status
                    return 0
                    ;;
                CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED)
                    echo $stack_status
                    return 1
                    ;;
            esac
        fi
    done
    aws cloudformation describe-stacks --output=text --stack-name "$1" --query 'Stacks[0].StackStatus'
    return 1
}

stack_name="$1"
ssh_key_pem="$2"
chmod 600 "$ssh_key_pem" || exit $?
#get_stack_status $stack_name
set -x

bastion_ip="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`BastionIp`].OutputValue[]')"
ci_url="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`CiUrl`].OutputValue[]')"
woo_url="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`WooUrl`].OutputValue[]')"
api_stack="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`ApiStack`].OutputValue[]')"
scribe_stack="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`ScribeStack`].OutputValue[]')"

api_asg="$(aws cloudformation describe-stacks --output=text --stack-name $api_stack --query 'Stacks[0].Outputs[?OutputKey==`APIInstanceGroup`].OutputValue[]')"
elb_url="$(aws cloudformation describe-stacks --output=text --stack-name $api_stack --query 'Stacks[0].Outputs[?OutputKey==`URL`].OutputValue[]')"
scribe_asg="$(aws cloudformation describe-stacks --output=text --stack-name $scribe_stack --query 'Stacks[0].Outputs[?OutputKey==`ScribeInstanceGroup`].OutputValue[]')"

api_instance_id="$(aws autoscaling describe-auto-scaling-groups --output=text --auto-scaling-group-names $api_asg --query 'AutoScalingGroups[0].Instances[0].InstanceId')"
scribe_instance_id="$(aws autoscaling describe-auto-scaling-groups --output=text --auto-scaling-group-names $scribe_asg --query 'AutoScalingGroups[0].Instances[0].InstanceId')"

api_ip="$(aws ec2 describe-instances --output=text --instance-ids $api_instance_id --query 'Reservations[0].Instances[0].PrivateIpAddress')"
scribe_ip="$(aws ec2 describe-instances --output=text --instance-ids $scribe_instance_id --query 'Reservations[0].Instances[0].PrivateIpAddress')"

[ -z "$api_ip" -o -z "$scribe_ip" ] && exit 1

ssh_cmd="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t -t"

echo "Integration Test Stack: $stack_name"
echo
echo

echo 'NETWORK TESTS'
echo '------------------------------------------------------------------------------'
# NTPD
ntpserver=$(grep '^server' /etc/ntp.conf | head -n 1 | awk '{print $2}')
echo "Test NTP to $ntpserver"
$ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "$ssh_cmd $api_ip \"sudo sh -c 'service ntpd stop > /dev/null && ntpdate $ntpserver && service ntpd start > /dev/null && service ntpd status'\"" || exit $?
$ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "$ssh_cmd $scribe_ip \"sudo sh -c 'service ntpd stop > /dev/null && ntpdate $ntpserver && service ntpd start > /dev/null && service ntpd status'\"" || exit $?
# HTTP
echo "Test HTTP to http://checkip.amazonaws.com/"
$ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "$ssh_cmd $api_ip \"curl -v --fail --connect-timeout 15 --max-time 30 http://checkip.amazonaws.com/\"" || exit $?
$ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "$ssh_cmd $scribe_ip \"curl -v --fail --connect-timeout 15 --max-time 30 http://checkip.amazonaws.com/\"" || exit $?
# HTTPS
echo "Test HTTPS to https://www.google.com/"
$ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "$ssh_cmd $api_ip \"curl -v --fail --connect-timeout 15 --max-time 30 https://www.google.com/ > /dev/null\"" || exit $?
$ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "$ssh_cmd $scribe_ip \"curl -v --fail --connect-timeout 15 --max-time 30 https://www.google.com > /dev/null\"" || exit $?

# give Jenkins times to come online
sleep 30
echo 
echo "Validating Jenkins came online: $ci_url/"
timeout_ts=$((`date +%s` + 1800))
curl_cmd="curl -v --fail --connect-timeout 10 --max-time 15 $ci_url/"
while [ $(date +%s) -le $timeout_ts ] && sleep 10; do
    if $curl_cmd | grep -qi jenkins; then
        break
    fi
done
$curl_cmd > /dev/null || exit $?
echo
echo

echo 'API TEST RESULTS'
echo '------------------------------------------------------------------------------'
$ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "$ssh_cmd $api_ip \"cd /opt/promotably/api && sudo ../api-integration-test.sh\"" || exit $?

echo
echo

echo 'SCRIBE TEST RESULTS'
echo '------------------------------------------------------------------------------'
$ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "$ssh_cmd $scribe_ip \"cd /opt/promotably/scribe && sudo ../scribe-integration-test.sh\"" || exit $?

echo
echo

echo '------------------------------------------------------------------------------'

aws cloudformation update-stack --stack-name $scribe_stack \
    --use-previous-template --capabilities CAPABILITY_IAM --parameters \
    ParameterKey=Environment,ParameterValue=staging \
    ParameterKey=ArtifactBucket,UsePreviousValue=true \
    ParameterKey=ArtifactPath,UsePreviousValue=true \
    ParameterKey=KeyPair,UsePreviousValue=true \
    ParameterKey=DBName,UsePreviousValue=true \
    ParameterKey=DBHost,UsePreviousValue=true \
    ParameterKey=DBPort,UsePreviousValue=true \
    ParameterKey=DBUsername,UsePreviousValue=true \
    ParameterKey=DBPassword,UsePreviousValue=true \
    ParameterKey=DBClientSecGrp,UsePreviousValue=true \
    ParameterKey=KinesisStreamA,UsePreviousValue=true \
    ParameterKey=KinesisStreamB,UsePreviousValue=true \
    ParameterKey=VpcId,UsePreviousValue=true \
    ParameterKey=VpcDefaultSecurityGroup,UsePreviousValue=true \
    ParameterKey=AvailabilityZones,UsePreviousValue=true \
    ParameterKey=PublicSubnets,UsePreviousValue=true || exit $?

aws cloudformation update-stack --stack-name $api_stack \
    --use-previous-template --capabilities CAPABILITY_IAM --parameters \
    ParameterKey=Environment,ParameterValue=staging \
    ParameterKey=ArtifactBucket,UsePreviousValue=true \
    ParameterKey=ArtifactPath,UsePreviousValue=true \
    ParameterKey=DashboardRef,UsePreviousValue=true \
    ParameterKey=KeyPair,UsePreviousValue=true \
    ParameterKey=RedisCluster,UsePreviousValue=true \
    ParameterKey=RedisClientSecGrp,UsePreviousValue=true \
    ParameterKey=DBName,UsePreviousValue=true \
    ParameterKey=DBHost,UsePreviousValue=true \
    ParameterKey=DBPort,UsePreviousValue=true \
    ParameterKey=DBUsername,UsePreviousValue=true \
    ParameterKey=DBPassword,UsePreviousValue=true \
    ParameterKey=DBClientSecGrp,UsePreviousValue=true \
    ParameterKey=KinesisStreamA,UsePreviousValue=true \
    ParameterKey=KinesisStreamB,UsePreviousValue=true \
    ParameterKey=VpcId,UsePreviousValue=true \
    ParameterKey=VpcDefaultSecurityGroup,UsePreviousValue=true \
    ParameterKey=NATSecurityGroup,UsePreviousValue=true \
    ParameterKey=AvailabilityZones,UsePreviousValue=true \
    ParameterKey=PublicSubnets,UsePreviousValue=true \
    ParameterKey=PrivateSubnets,UsePreviousValue=true \
    ParameterKey=DnsOverride,UsePreviousValue=true || exit $?

scribe_stack_status=$(get_stack_status $scribe_stack update)
rc=$?

echo
echo "SCRIBE STACK STATUS AFTER UPDATE TO STAGING: $scribe_stack_status"
[ $rc = 0 ] || exit $rc
set -x

api_stack_status=$(get_stack_status $api_stack update)
rc=$?

echo
echo "API STACK STATUS AFTER UPDATE TO STAGING: $api_stack_status"
[ $rc = 0 ] || exit $rc
set -x

# give ELB time to validate health checks
sleep 30
echo
echo "Validating api health-check: $elb_url/health-check"
timeout_ts=$((`date +%s` + 1800))
curl_cmd="curl -v --fail --connect-timeout 10 --max-time 15 $elb_url/health-check"
while [ $(date +%s) -le $timeout_ts ] && sleep 10; do
    if $curl_cmd | grep -q "I'm here"; then
        break
    fi
done
$curl_cmd || exit $?

echo
echo "Validating that / returns a 200 OK: $elb_url/"
curl -v --fail --connect-timeout 10 --max-time 15 $elb_url/ || exit $?
