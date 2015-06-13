#!/bin/bash

: ${KEY_BUCKET:=promotably-keyvault}

# Attempt to detect if we're on a dev's system
[ -n "$AWS_DEFAULT_REGION" ] || export AWS_DEFAULT_REGION=us-east-1
awscmd='aws'
if [ -f ~/.aws/credentials -a "$CI_NAME" != 'jenkins' ]; then
    awscmd="aws --profile promotably"
    unset AWS_ACCOUNT_ID AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SECRET_KEY
fi

stack_name="$1"
ssh_key=$($awscmd cloudformation describe-stacks --stack-name "$stack_name" \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`SshKey`].ParameterValue')
ssh_key_pem="$ssh_key.pem"
$awscmd s3 cp "s3://$KEY_BUCKET/$ssh_key_pem" ./
chmod 600 "$ssh_key_pem" || exit $?

set -x

bastion_ip="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`BastionIp`].OutputValue[]')"
ci_url="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`CiUrl`].OutputValue[]')"
woo_url="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`WooUrl`].OutputValue[]')"
rds_stack="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`RdsStack`].OutputValue[]')"
api_stack="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`ApiStack`].OutputValue[]')"
scribe_stack="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`ScribeStack`].OutputValue[]')"
metricsag_stack="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`MetricsAggregatorStack`].OutputValue[]')"

api_asg="$($awscmd cloudformation describe-stacks --output=text --stack-name $api_stack --query 'Stacks[0].Outputs[?OutputKey==`APIInstanceGroup`].OutputValue[]')"
api_elb_url="$($awscmd cloudformation describe-stacks --output=text --stack-name $api_stack --query 'Stacks[0].Outputs[?OutputKey==`URL`].OutputValue[]')"
db_elb_host="$($awscmd cloudformation describe-stacks --output=text --stack-name $api_stack --query 'Stacks[0].Outputs[?OutputKey==`DashboardHostname`].OutputValue[]')"
scribe_asg="$($awscmd cloudformation describe-stacks --output=text --stack-name $scribe_stack --query 'Stacks[0].Outputs[?OutputKey==`ScribeInstanceGroup`].OutputValue[]')"
metricsag_asg="$($awscmd cloudformation describe-stacks --output=text --stack-name $metricsag_stack --query 'Stacks[0].Outputs[?OutputKey==`LaunchGroup`].OutputValue[]')"

api_instance_id="$($awscmd autoscaling describe-auto-scaling-groups --output=text --auto-scaling-group-names $api_asg --query 'AutoScalingGroups[0].Instances[0].InstanceId')"
scribe_instance_id="$($awscmd autoscaling describe-auto-scaling-groups --output=text --auto-scaling-group-names $scribe_asg --query 'AutoScalingGroups[0].Instances[0].InstanceId')"
metricsag_instance_id="$($awscmd autoscaling describe-auto-scaling-groups --output=text --auto-scaling-group-names $metricsag_asg --query 'AutoScalingGroups[0].Instances[0].InstanceId')"

api_ip="$($awscmd ec2 describe-instances --output=text --instance-ids $api_instance_id --query 'Reservations[0].Instances[0].PrivateIpAddress')"
scribe_ip="$($awscmd ec2 describe-instances --output=text --instance-ids $scribe_instance_id --query 'Reservations[0].Instances[0].PrivateIpAddress')"
metricsag_ip="$($awscmd ec2 describe-instances --output=text --instance-ids $metricsag_instance_id --query 'Reservations[0].Instances[0].PrivateIpAddress')"

[ -z "$api_ip" -o -z "$scribe_ip" -o -z "$metricsag_ip" ] && exit 1

ssh_cmd="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t -t"

echo "Integration Test Stack: $stack_name"
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
