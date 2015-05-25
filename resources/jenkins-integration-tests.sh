#!/bin/bash

: ${KEY_BUCKET:=promotably-keyvault}

# helper function to wait for stack creation/update
get_stack_status() {
    set +x
    timeout_ts=$((`date +%s` + 1800))
    while [ $(date +%s) -le $timeout_ts ]; do
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
        sleep 20
    done
    aws cloudformation describe-stacks --output=text --stack-name "$1" --query 'Stacks[0].StackStatus'
    return 1
}

if [ "$(uname -s)" = 'Darwin' ]; then
    sed_cmd='sed -E'
else
    sed_cmd='sed -r'
fi

stack_name="$1"
ssh_key=$(aws cloudformation describe-stacks --stack-name "$stack_name" \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`SshKey`].ParameterValue')
ssh_key_pem="$ssh_key.pem"
aws s3 cp "s3://$KEY_BUCKET/$ssh_key_pem" ./
chmod 600 "$ssh_key_pem" || exit $?

set -x

bastion_ip="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`BastionIp`].OutputValue[]')"
ci_url="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`CiUrl`].OutputValue[]')"
woo_url="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`WooUrl`].OutputValue[]')"
rds_stack="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`RdsStack`].OutputValue[]')"
api_stack="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`ApiStack`].OutputValue[]')"
scribe_stack="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`ScribeStack`].OutputValue[]')"
metricsag_stack="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`MetricsAggregatorStack`].OutputValue[]')"

api_asg="$(aws cloudformation describe-stacks --output=text --stack-name $api_stack --query 'Stacks[0].Outputs[?OutputKey==`APIInstanceGroup`].OutputValue[]')"
api_elb_url="$(aws cloudformation describe-stacks --output=text --stack-name $api_stack --query 'Stacks[0].Outputs[?OutputKey==`URL`].OutputValue[]')"
db_elb_host="$(aws cloudformation describe-stacks --output=text --stack-name $api_stack --query 'Stacks[0].Outputs[?OutputKey==`DashboardHostname`].OutputValue[]')"
scribe_asg="$(aws cloudformation describe-stacks --output=text --stack-name $scribe_stack --query 'Stacks[0].Outputs[?OutputKey==`ScribeInstanceGroup`].OutputValue[]')"
metricsag_asg="$(aws cloudformation describe-stacks --output=text --stack-name $metricsag_stack --query 'Stacks[0].Outputs[?OutputKey==`LaunchGroup`].OutputValue[]')"
db_name="$(aws cloudformation describe-stacks --output=text --stack-name $rds_stack --query 'Stacks[0].Outputs[?OutputKey==`DBName`].OutputValue[]')"
db_host="$(aws cloudformation describe-stacks --output=text --stack-name $rds_stack --query 'Stacks[0].Outputs[?OutputKey==`DBHost`].OutputValue[]')"
db_port="$(aws cloudformation describe-stacks --output=text --stack-name $rds_stack --query 'Stacks[0].Outputs[?OutputKey==`DBPort`].OutputValue[]')"

api_instance_id="$(aws autoscaling describe-auto-scaling-groups --output=text --auto-scaling-group-names $api_asg --query 'AutoScalingGroups[0].Instances[0].InstanceId')"
scribe_instance_id="$(aws autoscaling describe-auto-scaling-groups --output=text --auto-scaling-group-names $scribe_asg --query 'AutoScalingGroups[0].Instances[0].InstanceId')"
metricsag_instance_id="$(aws autoscaling describe-auto-scaling-groups --output=text --auto-scaling-group-names $metricsag_asg --query 'AutoScalingGroups[0].Instances[0].InstanceId')"

api_ip="$(aws ec2 describe-instances --output=text --instance-ids $api_instance_id --query 'Reservations[0].Instances[0].PrivateIpAddress')"
scribe_ip="$(aws ec2 describe-instances --output=text --instance-ids $scribe_instance_id --query 'Reservations[0].Instances[0].PrivateIpAddress')"
metricsag_ip="$(aws ec2 describe-instances --output=text --instance-ids $metricsag_instance_id --query 'Reservations[0].Instances[0].PrivateIpAddress')"

[ -z "$api_ip" -o -z "$scribe_ip" -o -z "$metricsag_ip" ] && exit 1

ssh_cmd="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t -t"

echo "Integration Test Stack: $stack_name"
echo
echo

echo 'NETWORK TESTS'
echo '------------------------------------------------------------------------------'
# SSH sanity check
echo "Bastion Sanity Check"
$ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "whoami"|| exit $?
#ntpserver=$(grep '^server' /etc/ntp.conf | head -n 1 | awk '{print $2}')
for priv_ip in $api_ip $scribe_ip $metricsag_ip ; do
    echo "Network Tests for $priv_ip"
    $ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "$ssh_cmd $priv_ip \"sudo whoami\"" || exit $?
    # TODO Make less brittle and re-enable
    #$ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "$ssh_cmd $priv_ip \"sudo sh -c 'service ntpd stop > /dev/null && ntpdate $ntpserver && service ntpd start > /dev/null && service ntpd status'\"" || exit $?
    $ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "$ssh_cmd $priv_ip \"curl -v --fail --connect-timeout 15 --max-time 30 http://checkip.amazonaws.com/\"" || exit $?
    $ssh_cmd -i $ssh_key_pem ec2-user@$bastion_ip "$ssh_cmd $priv_ip \"curl -v --fail --connect-timeout 15 --max-time 30 https://www.google.com/ > /dev/null\"" || exit $?
    echo
done

echo
echo "Setting up ssh tunnel to database"
local_db_port=$(($RANDOM % 10000 + 20000))
$ssh_cmd -i $ssh_key_pem -f -N -o ExitOnForwardFailure=yes -L $local_db_port:$db_host:$db_port ec2-user@$bastion_ip
set -x

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

# give ELB time to validate health checks
sleep 30
echo
echo "Validating api health-check: $api_elb_url/health-check"
timeout_ts=$((`date +%s` + 1800))
curl_cmd="curl -v --fail --connect-timeout 10 --max-time 15 $api_elb_url/health-check"
while [ $(date +%s) -le $timeout_ts ] && sleep 10; do
    if $curl_cmd; then
        break
    fi
done
$curl_cmd || exit $?

echo
echo "Validating that /login returns a 200 OK: $api_elb_url/login"
curl -v --fail --connect-timeout 10 --max-time 15 $api_elb_url/login > /dev/null || exit $?

echo
echo "Validating dashboard redirect to http://$db_elb_host"
curl -v "http://$db_elb_host" 2>&1 | fgrep 'Location: https://' || echo $?

echo
echo 'API TEST RESULTS'
echo '------------------------------------------------------------------------------'

#export ARTIFACT_BUCKET=
#export DASHBOARD_HTML_PATH=
#export DASHBOARD_INDEX_PATH=
#export KINESIS_A=
#export REDIS_HOST=
#export REDIS_PORT=
export RDS_DB_NAME=$db_name
export RDS_HOST=127.0.0.1
export RDS_PORT=$local_db_port
export RDS_USER=promotably
export RDS_PW=promotably
export ENV=integration
export MIDJE_COLORIZE=false
#export STACKNAME=
export LOGGLY_URL="http://logs-01.loggly.com/inputs/2032adee-6213-469d-ba58-74993611570a/tag/integration,testrunner/"
#export LOG_DIR=
export TARGET_URL=$api_elb_url

lein deps > /dev/null 2>&1
lein midje api.integration.*

echo
ps -ef | grep ssh | grep "$local_db_port:$db_host:$db_port" | awk '{print $2}' | xargs kill
