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

# helper function to wait for stack creation/update
get_stack_status() {
    set +x
    timeout_ts=$((`date +%s` + 1800))
    while [ $(date +%s) -le $timeout_ts ] && sleep 20; do
        stack_status=$($awscmd cloudformation describe-stacks --output=text --stack-name "$1" --query 'Stacks[0].StackStatus')
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
    $awscmd cloudformation describe-stacks --output=text --stack-name "$1" --query 'Stacks[0].StackStatus'
    return 1
}

set -ex

src_stack_ci_name=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`CiName`].ParameterValue')
dst_stack_ci_name=$($awscmd cloudformation describe-stacks --stack-name $dst_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`CiName`].ParameterValue')
src_stack_artifact_bucket=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`ArtifactBucket`].ParameterValue')
dst_stack_artifact_bucket=$($awscmd cloudformation describe-stacks --stack-name $dst_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`ArtifactBucket`].ParameterValue')
src_stack_metadata_bucket=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`MetaDataBucket`].ParameterValue')
dst_stack_metadata_bucket=$($awscmd cloudformation describe-stacks --stack-name $dst_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`MetaDataBucket`].ParameterValue')

if [ -z "$src_stack_ci_name"         -o -z "$dst_stack_ci_name" -o \
     -z "$src_stack_artifact_bucket" -o -z "$dst_stack_artifact_bucket" -o \
     -z "$src_stack_metadata_bucket" -o -z "$dst_stack_metadata_bucket" ]; then
    echo "Fatal: Unable to query stack CI parameters" >&2
    exit 1
fi

if [ "$src_stack_ci_name"         != "$dst_stack_ci_name" -o \
     "$src_stack_artifact_bucket" != "$dst_stack_artifact_bucket" -o \
     "$src_stack_metadata_bucket" != "$dst_stack_metadata_bucket" ]; then
    echo "Fatal: Stack CI parameters do not match" >&2
    exit 1
fi

squadron_ref=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`SquadronRef`].ParameterValue')
api_ref=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`ApiRef`].ParameterValue')
scribe_ref=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`ScribeRef`].ParameterValue')
dashboard_ref=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`DashboardRef`].ParameterValue')
metrics_aggregator_ref=$($awscmd cloudformation describe-stacks --stack-name $src_stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`MetricsAggregatorRef`].ParameterValue')

if [ -z "$squadron_ref" -o -z "$api_ref" -o -z "$scribe_ref" -o -z "$dashboard_ref" -o -z "$metrics_aggregator_ref" ]; then
    echo "Fatal: Unable to query source stack parameters" >&2
    exit 1
fi

export CI_NAME="$dst_stack_ci_name"
export ARTIFACT_BUCKET="$dst_stack_artifact_bucket"
export METADATA_BUCKET="$dst_stack_metadata_bucket"

general_stack_params=''
for param in $($awscmd cloudformation describe-stacks --stack-name $dst_stack_name \
  --output=text --query 'Stacks[0].Parameters[].ParameterKey') ; do
    case "$param" in
        SquadronRef)
            squadronref_param="ParameterKey=SquadronRef,ParameterValue=$squadron_ref"
            ;;
        ApiRef)
            apiref_param="ParameterKey=ApiRef,ParameterValue=$api_ref"
            ;;
        ScribeRef)
            scriberef_param="ParameterKey=ScribeRef,ParameterValue=$scribe_ref"
            ;;
        DashboardRef)
            dashboardref_param="ParameterKey=DashboardRef,ParameterValue=$dashboard_ref"
            ;;
        MetricsAggregatorRef)
            metrics_aggregatorref_param="ParameterKey=MetricsAggregatorRef,ParameterValue=$metrics_aggregator_ref"
            ;;
        *)
            general_stack_params="$general_stack_params ParameterKey=$param,UsePreviousValue=true"
    esac
done

# validate cfn templates
templates_validated=0
for cfn_json in $($awscmd s3 ls "s3://$ARTIFACT_BUCKET/$CI_NAME/squadron/$squadron_ref/" | awk '{print $4}' | grep '^cfn-.*[.]json$') ; do
    $awscmd cloudformation validate-template --output=text \
        --template-url "https://$ARTIFACT_BUCKET.s3.amazonaws.com/$CI_NAME/squadron/$squadron_ref/$cfn_json"
    templates_validated=$(($templates_validated + 1))
done
if [ $templates_validated -eq 0 ]; then
    echo "Fatal: No CloudFormation templates found in s3://$ARTIFACT_BUCKET/$CI_NAME/squadron/$squadron_ref/" >&2
    exit 1
fi
template_option="--template-url https://$ARTIFACT_BUCKET.s3.amazonaws.com/$CI_NAME/squadron/$squadron_ref/cfn-promotably.json"

# make sure artifacts are there
for s3_file in api/$api_ref/standalone.jar api/$api_ref/source.zip api/$api_ref/apid \
               scribe/$scribe_ref/standalone.jar scribe/$scribe_ref/source.zip scribe/$scribe_ref/scribed \
               dashboard/$dashboard_ref/index.html \
               metrics-aggregator/$metrics_aggregator_ref/standalone.jar metrics-aggregator/$metrics_aggregator_ref/source.zip metrics-aggregator/$metrics_aggregator_ref/mad ; do
    $awscmd s3 ls s3://$ARTIFACT_BUCKET/$CI_NAME/$s3_file > /dev/null
done

$awscmd cloudformation update-stack --stack-name $dst_stack_name $template_option \
    --capabilities CAPABILITY_IAM --parameters \
    $squadronref_param $apiref_param $scriberef_param $dashboardref_param $metrics_aggregatorref_param \
    $general_stack_params

get_stack_status $dst_stack_name update
