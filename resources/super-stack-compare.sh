#!/bin/bash

# Attempt to detect if we're on a dev's system
[ -n "$AWS_DEFAULT_REGION" ] || export AWS_DEFAULT_REGION=us-east-1
awscmd='aws'
if [ -f ~/.aws/credentials -a "$CI_NAME" != 'jenkins' ]; then
    awscmd="aws --profile promotably"
    unset AWS_ACCOUNT_ID AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SECRET_KEY
fi

print_usage() {
    set +ex
    cat >&2 << _END_
Usage: $(basename $0) -s <stack_name> -d <stack_name>

Options:
    -s <stack_name>     CloudFormation source stack name (Required)
    -d <stack_name>     CloudFormation destination stack name (Required)
_END_

    if [ -n "$1" ]; then
        exit $1
    fi
}

src_stack_name=''
dst_stack_name=''
opts='hs:d:'
while getopts "$opts" opt; do
    case "$opt" in
        h) print_usage 0;;
        s) src_stack_name="$OPTARG" ;;
        d) dst_stack_name="$OPTARG" ;;
        \?) print_usage 1;;
        #-) shift; break ;;
    esac
done

[ -n "$src_stack_name" ] || print_usage 1
[ -n "$dst_stack_name" ] || print_usage 1

echo
echo "WARNING: This script will attempt to checkout master and git pull each product!"
echo "         Make sure you don't have any unstashed changes!!!"
echo
echo -n "Press <ENTER> to continue ..."
read junk

set -e

src_squadron_ref=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`SquadronRef`].ParameterValue')
src_api_ref=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`ApiRef`].ParameterValue')
src_scribe_ref=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`ScribeRef`].ParameterValue')
src_dashboard_ref=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`DashboardRef`].ParameterValue')
src_metrics_aggregator_ref=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`MetricsAggregatorRef`].ParameterValue')

dst_squadron_ref=$($awscmd cloudformation describe-stacks --stack-name $dst_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`SquadronRef`].ParameterValue')
dst_api_ref=$($awscmd cloudformation describe-stacks --stack-name $dst_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`ApiRef`].ParameterValue')
dst_scribe_ref=$($awscmd cloudformation describe-stacks --stack-name $dst_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`ScribeRef`].ParameterValue')
dst_dashboard_ref=$($awscmd cloudformation describe-stacks --stack-name $dst_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`DashboardRef`].ParameterValue')
dst_metrics_aggregator_ref=$($awscmd cloudformation describe-stacks --stack-name $dst_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`MetricsAggregatorRef`].ParameterValue')

if [ "$src_squadron_ref" != "$dst_squadron_ref" ]; then
    echo
    echo '==== SQUADRON ===='
    echo "++++ ${src_squadron_ref}...${dst_squadron_ref} ++++"
    pushd "$(dirname $0)/../../squadron" > /dev/null
    git checkout master
    git pull
    git log "${src_squadron_ref}...${dst_squadron_ref}"
    popd > /dev/null
fi

if [ "$src_api_ref" != "$dst_api_ref" ]; then
    echo
    echo '==== API ===='
    echo "++++ ${src_api_ref}...${dst_api_ref} ++++"
    pushd "$(dirname $0)/../../api" > /dev/null
    git checkout master
    git pull
    git log "${src_api_ref}...${dst_api_ref}"
    popd > /dev/null
fi

if [ "$src_scribe_ref" != "$dst_scribe_ref" ]; then
    echo
    echo '==== SCRIBE ===='
    echo "++++ ${src_scribe_ref}...${dst_scribe_ref} ++++"
    pushd "$(dirname $0)/../../scribe" > /dev/null
    git checkout master
    git pull
    git log "${src_scribe_ref}...${dst_scribe_ref}"
    popd > /dev/null
fi

if [ "$src_dashboard_ref" != "$dst_dashboard_ref" ]; then
    echo
    echo '==== DASHBOARD ===='
    echo "++++ ${src_dashboard_ref}...${dst_dashboard_ref} ++++"
    pushd "$(dirname $0)/../../dashboard" > /dev/null
    git checkout master
    git pull
    git log "${src_dashboard_ref}...${dst_dashboard_ref}"
    popd > /dev/null
fi

if [ "$src_metrics_aggregator_ref" != "$dst_metrics_aggregator_ref" ]; then
    echo
    echo '==== METRICS-AGG ===='
    echo "++++ ${src_metrics_aggregator_ref}...${dst_metrics_aggregator_ref} ++++"
    pushd "$(dirname $0)/../../metrics-aggregator" > /dev/null
    git checkout master
    git pull
    git log "${src_metrics_aggregator_ref}...${dst_metrics_aggregator_ref}"
    popd > /dev/null
fi
