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

api_stack="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`ApiStack`].OutputValue[]')"
db_elb_url="$($awscmd cloudformation describe-stacks --output=text --stack-name $api_stack --query 'Stacks[0].Outputs[?OutputKey==`DashboardURL`].OutputValue[]')"

echo "Integration Test Stack: $stack_name"
echo
echo 'DASHBOARD TESTS'
echo '------------------------------------------------------------------------------'
set -x
gulp test:integration --urlroot=$db_elb_url
