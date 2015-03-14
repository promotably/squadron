#!/bin/bash

stack_name="$1"

if [ -z "$stack_name" ]; then
    echo "Usage: $(basename $0) <integration-stack-name>" >&2
    exit 1
fi

# Attempt to detect if we're on a dev's system
[ -n "$AWS_DEFAULT_REGION" ] || export AWS_DEFAULT_REGION=us-east-1
awscmd='aws'
if [ -f ~/.aws/credentials -a "$CI_NAME" != 'jenkins' ]; then
    awscmd="aws --profile promotably"
    unset AWS_ACCOUNT_ID AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SECRET_KEY
fi

set -x

bastion_ip="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`BastionIp`].OutputValue[]')"
ssh_key_name="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Parameters[?ParameterKey==`SshKey`].ParameterValue[]')"
rds_stack="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`RdsStack`].OutputValue[]')"
rds_host="$($awscmd cloudformation describe-stacks --output=text --stack-name $rds_stack --query 'Stacks[0].Outputs[?OutputKey==`DBHost`].OutputValue[]')"

$awscmd s3 cp s3://promotably-keyvault/$ssh_key_name.pem ~/${ssh_key_name}$$.pem
chmod 600 ~/${ssh_key_name}$$.pem
ssh -L 15432:$rds_host:5432 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/${ssh_key_name}$$.pem ec2-user@$bastion_ip
rm -f ~/${ssh_key_name}$$.pem
