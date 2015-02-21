#!/bin/bash

stack_name="$1"

if [ -z "$stack_name" ]; then
    echo "Usage: $(basename $0) <integration-stack-name>" >&2
    exit 1
fi

set -x

bastion_ip="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`BastionIp`].OutputValue[]')"
ssh_key_name="$(aws cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Parameters[?ParameterKey==`SshKey`].ParameterValue[]')"

aws s3 cp s3://promotably-keyvault/$ssh_key_name.pem ~/${ssh_key_name}$$.pem
chmod 600 ~/${ssh_key_name}$$.pem
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/${ssh_key_name}$$.pem ec2-user@$bastion_ip
rm -f ~/${ssh_key_name}$$.pem
