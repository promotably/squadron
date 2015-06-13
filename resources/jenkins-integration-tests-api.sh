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


bastion_ip="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`BastionIp`].OutputValue[]')"
rds_stack="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`RdsStack`].OutputValue[]')"
api_stack="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`ApiStack`].OutputValue[]')"
api_elb_url="$($awscmd cloudformation describe-stacks --output=text --stack-name $api_stack --query 'Stacks[0].Outputs[?OutputKey==`URL`].OutputValue[]')":
db_name="$($awscmd cloudformation describe-stacks --output=text --stack-name $rds_stack --query 'Stacks[0].Outputs[?OutputKey==`DBName`].OutputValue[]')"
db_host="$($awscmd cloudformation describe-stacks --output=text --stack-name $rds_stack --query 'Stacks[0].Outputs[?OutputKey==`DBHost`].OutputValue[]')"
db_port="$($awscmd cloudformation describe-stacks --output=text --stack-name $rds_stack --query 'Stacks[0].Outputs[?OutputKey==`DBPort`].OutputValue[]')"

ssh_cmd="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t -t"

echo "Integration Test Stack: $stack_name"
echo
echo 'API TEST RESULTS'
echo '------------------------------------------------------------------------------'
echo
echo "Setting up ssh tunnel to database"
local_db_port=$(($RANDOM % 10000 + 20000))
echo "$ssh_cmd -i $ssh_key_pem -f -N -o ExitOnForwardFailure=yes -L $local_db_port:$db_host:$db_port ec2-user@$bastion_ip"
$ssh_cmd -i $ssh_key_pem -f -N -o ExitOnForwardFailure=yes -L $local_db_port:$db_host:$db_port ec2-user@$bastion_ip

cat > integration-test-env.sh << _END_
##### Environment if you want to re-run lein midje api.integration.*:"
# TUNNEL CMD: $ssh_cmd -i $ssh_key_pem -f -N -o ExitOnForwardFailure=yes -L $local_db_port:$db_host:$db_port ec2-user@$bastion_ip
#
## integration tests should not need these
#export ARTIFACT_BUCKET=
#export DASHBOARD_HTML_PATH=
#export DASHBOARD_INDEX_PATH=
#export KINESIS_A=
#export REDIS_HOST=
#export REDIS_PORT=
##
export RDS_DB_NAME=$db_name
export RDS_HOST=127.0.0.1
export RDS_PORT=$local_db_port
export RDS_USER=promotably
export RDS_PW=promotably
export ENV=integration
export MIDJE_COLORIZE=false
export LOGGLY_URL="http://logs-01.loggly.com/inputs/2032adee-6213-469d-ba58-74993611570a/tag/integration,testrunner/"
#export LOG_DIR=
export TARGET_URL=$api_elb_url
_END_

echo
set -x

. integration-test-env.sh

lein deps > /dev/null 2>&1
lein midje api.integration.*

echo
ps -ef | grep ssh | grep "$local_db_port:$db_host:$db_port" | awk '{print $2}' | xargs kill
cat integration-test-env.sh
echo
rm -f $ssh_key_pem integration-test-env.sh
