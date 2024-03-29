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
Usage: $(basename $0) -s <stack_name> [-u] [-p <project>] [-r <commit_sha>] [OTHER OPTIONS...]

Options:
    -s <stack_name>     CloudFormation stack name (Required)
    -u                  Update to all 'known-good' app versions
    -p <project>        Which project to override 'known-good' version
    -r <commit_sha>     Commit sha of project (required if -p specified)
    -w <cidr>           CIDR to pass to SshFrom paramter ('myip' will set to your public ip address)
    -e <env>            Environment parameter (integration, staging, etc.)
_END_

    if [ -n "$1" ]; then
        exit $1
    fi
}

stack_name=''
refresh=''
project=''
gitref=''
ssh_from=''
environment=''
opts='hs:up:r:w:e:'
while getopts "$opts" opt; do
    #echo "OPT: $opt"
    case "$opt" in
        h) print_usage 0;;
        s) stack_name="$OPTARG" ;;
        u) refresh='true' ;;
        p) project="$OPTARG" ;;
        r) gitref="$OPTARG" ;;
        w) ssh_from="$OPTARG" ;;
        e) environment="$OPTARG" ;;
        \?) print_usage 1;;
        #-) shift; break ;;
    esac
done

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

if [ "$ssh_from" = 'myip' ]; then
    ssh_from="$(curl http://icanhazip.com/)/32"
fi

stack_ci_name=$($awscmd cloudformation describe-stacks --stack-name $stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`CiName`].ParameterValue')
stack_artifact_bucket=$($awscmd cloudformation describe-stacks --stack-name $stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`ArtifactBucket`].ParameterValue')
stack_metadata_bucket=$($awscmd cloudformation describe-stacks --stack-name $stack_name \
    --output=text --query 'Stacks[0].Parameters[?ParameterKey==`MetaDataBucket`].ParameterValue')
if [ -z "$stack_ci_name" -o -z "$stack_artifact_bucket" -o -z "$stack_metadata_bucket" ]; then
    echo "Fatal: Unable to query Stack parameters" >&2
    exit 1
fi

export CI_NAME="$stack_ci_name"
export ARTIFACT_BUCKET="$stack_artifact_bucket"
export METADATA_BUCKET="$stack_metadata_bucket"

general_stack_params=''
for param in $($awscmd cloudformation describe-stacks --stack-name $stack_name \
  --output=text --query 'Stacks[0].Parameters[].ParameterKey') ; do
    case "$param" in
        SquadronRef)
            squadronref_param='ParameterKey=SquadronRef,UsePreviousValue=true'
            ;;
        ApiRef)
            apiref_param='ParameterKey=ApiRef,UsePreviousValue=true'
            ;;
        ScribeRef)
            scriberef_param='ParameterKey=ScribeRef,UsePreviousValue=true'
            ;;
        DashboardRef)
            dashboardref_param='ParameterKey=DashboardRef,UsePreviousValue=true'
            ;;
        MetricsAggregatorRef)
            metrics_aggregatorref_param='ParameterKey=MetricsAggregatorRef,UsePreviousValue=true'
            ;;
        Environment)
            environment_param='ParameterKey=Environment,UsePreviousValue=true'
            ;;
        SSHFrom)
            ssh_from_param='ParameterKey=SSHFrom,UsePreviousValue=true'
            ;;
        *)
            general_stack_params="$general_stack_params ParameterKey=$param,UsePreviousValue=true"
    esac
done

squadron_ref=''
api_ref=''
scribe_ref=''
dashboard_ref=''
metrics_aggregator_ref=''
if [ -n "$refresh" ]; then
    squadron_ref=$($awscmd s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/squadron/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
    api_ref=$($awscmd s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/api/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
    scribe_ref=$($awscmd s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/scribe/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
    dashboard_ref=$($awscmd s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/dashboard/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
    metrics_aggregator_ref=$($awscmd s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/metrics-aggregator/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
fi

if [ -n "$project" ]; then
    if [ -z "$gitref" ]; then
        print_usage 1
    fi
    case "$project" in
        squadron)
            squadron_ref=$gitref
            ;;
        api)
            api_ref=$gitref
            ;;
        scribe)
            scribe_ref=$gitref
            ;;
        dashboard)
            dashboard_ref=$gitref
            ;;
        metrics-aggregator)
            metrics_aggregator_ref=$gitref
            ;;
        *)
            echo "Fatal: Unknown project $project" >&2
            exit 1
            ;;
    esac
fi

# validate cfn templates if we're refreshing Squadron
template_option='--use-previous-template'
if [ -n "$squadron_ref" ]; then
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
    squadronref_param="ParameterKey=SquadronRef,ParameterValue=$squadron_ref"
    template_option="--template-url https://$ARTIFACT_BUCKET.s3.amazonaws.com/$CI_NAME/squadron/$squadron_ref/cfn-promotably.json"
fi

# make sure api artifacts are there if we're refreshing Api
if [ -n "$api_ref" ]; then
    for s3_file in api/$api_ref/standalone.jar api/$api_ref/source.zip api/$api_ref/apid ; do
        $awscmd s3 ls s3://$ARTIFACT_BUCKET/$CI_NAME/$s3_file > /dev/null
    done
    apiref_param="ParameterKey=ApiRef,ParameterValue=$api_ref"
fi

# make sure scribe artifacts are there if we're refreshing Scribe
if [ -n "$scribe_ref" ]; then
    for s3_file in scribe/$scribe_ref/standalone.jar scribe/$scribe_ref/source.zip scribe/$scribe_ref/scribed ; do
        $awscmd s3 ls s3://$ARTIFACT_BUCKET/$CI_NAME/$s3_file > /dev/null
    done
    scriberef_param="ParameterKey=ScribeRef,ParameterValue=$scribe_ref"
fi

# make sure dashboard artifacts are there if we're refreshing Dashboard
if [ -n "$dashboard_ref" ]; then
    for s3_file in dashboard/$dashboard_ref/index.html ; do
        $awscmd s3 ls s3://$ARTIFACT_BUCKET/$CI_NAME/$s3_file > /dev/null
    done
    dashboardref_param="ParameterKey=DashboardRef,ParameterValue=$dashboard_ref"
fi

# make sure metrics-aggregator artifacts are there if we're refreshing Metrics Aggregator
if [ -n "$metrics_aggregator_ref" ]; then
    for s3_file in metrics-aggregator/$metrics_aggregator_ref/standalone.jar metrics-aggregator/$metrics_aggregator_ref/source.zip metrics-aggregator/$metrics_aggregator_ref/mad ; do
        $awscmd s3 ls s3://$ARTIFACT_BUCKET/$CI_NAME/$s3_file > /dev/null
    done
    metrics_aggregatorref_param="ParameterKey=MetricsAggregatorRef,ParameterValue=$metrics_aggregator_ref"
fi

if [ -n "$ssh_from" ]; then
    ssh_from_param="ParameterKey=SSHFrom,ParameterValue=$ssh_from"
fi

if [ -n "$environment" ]; then
    environment_param="ParameterKey=Environment,ParameterValue=$environment"
fi

$awscmd cloudformation update-stack --stack-name $stack_name $template_option \
    --capabilities CAPABILITY_IAM --parameters \
    $squadronref_param $apiref_param $scriberef_param $dashboardref_param $metrics_aggregatorref_param \
    $environment_param $ssh_from_param \
    $general_stack_params

get_stack_status $stack_name update
