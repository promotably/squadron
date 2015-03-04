#!/bin/bash

# these should be set in the environment by our CI server
: ${ARTIFACT_BUCKET:=p_tmp}
: ${METADATA_BUCKET:=p_tmp}
: ${KEY_BUCKET:=promotably-keyvault}
: ${CI_NAME:=localdev}

print_usage() {
    set +ex
    cat >&2 << _END_
Usage: $(basename $0) -s <stack_name> [-p <project>] [-r <commit_sha>] [OTHER OPTIONS...]

Options:
    -s <stack_name>     CloudFormation stack name (Required)
    -p <project>        Which project to override 'known-good' version
    -r <commit_sha>     Commit sha of project (required if -p specified)
    -d <dns_suffix>     String to append to DNS names of stacks (eg: api-<dns_suffix>.promotably.com>)
    -w <cidr>           CIDR to pass to SshFrom paramter
    -e <env>            Environment parameter (integration, staging, etc.)
    -i <db_snap>        RDS DB Snapshot ID
_END_

    if [ -n "$1" ]; then
        exit $1
    fi
}

stack_name=''
project=''
gitref=''
dns_suffix=''
ssh_from=''
environment=''
db_snap=''
opts='hs:p:r:d:w:e:'
while getopts "$opts" opt; do
    #echo "OPT: $opt"
    case "$opt" in
        h) print_usage 0;;
        s) stack_name="$OPTARG" ;;
        p) project="$OPTARG" ;;
        r) gitref="$OPTARG" ;;
        d) dns_suffix="$OPTARG" ;;
        w) ssh_from="$OPTARG" ;;
        e) environment="$OPTARG" ;;
        i) db_snap="$OPTARG" ;;
        \?) print_usage 1;;
        #-) shift; break ;;
    esac
done

# helper function to wait for stack creation/update
get_stack_status() {
    set +x
    timeout_ts=$((`date +%s` + 3600))
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

set -ex

squadron_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/squadron/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
api_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/api/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
scribe_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/scribe/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
dashboard_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/dashboard/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)

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
        *)
            echo "Fatal: Unknown project $project" >&2
            exit 1
            ;;
    esac
fi

# The autogenerated stack names are too long for Route53 records
if [ -z "$dns_suffix" ]; then
    dns_suffix="$(echo $stack_name | openssl md5 | awk '{print $2}')"
fi

# validate cfn templates
templates_validated=0
for cfn_json in $(aws s3 ls "s3://$ARTIFACT_BUCKET/$CI_NAME/squadron/$squadron_ref/" | awk '{print $4}' | grep '^cfn-.*[.]json$') ; do
    aws cloudformation validate-template --output=text \
        --template-url "https://$ARTIFACT_BUCKET.s3.amazonaws.com/$CI_NAME/squadron/$squadron_ref/$cfn_json"
    templates_validated=$(($templates_validated + 1))
done
if [ $templates_validated -eq 0 ]; then
    echo "Fatal: No CloudFormation templates found in s3://$ARTIFACT_BUCKET/$CI_NAME/squadron/$squadron_ref/" >&2
    exit 1
fi

# make sure other build artifacts are there
for s3_file in dashboard/$dashboard_ref/index.html api/$api_ref/standalone.jar api/$api_ref/source.zip api/$api_ref/apid \
               scribe/$scribe_ref/standalone.jar scribe/$scribe_ref/source.zip scribe/$scribe_ref/scribed ; do
    aws s3 ls s3://$ARTIFACT_BUCKET/$CI_NAME/$s3_file > /dev/null
done

ssh_from_param=''
if [ -n "$ssh_from" ]; then
    ssh_from_param="ParameterKey=SSHFrom,ParameterValue=$ssh_from"
fi

environment_param=''
if [ -n "$environment" ]; then
    environment_param="ParameterKey=Environment,ParameterValue=$environment"
fi

db_snap=''
if [ -n "$db_snap" ]; then
    db_snap="ParameterKey=DBSnapshotId,ParameterValue=$db_snap"
fi

ssh_key="$CI_NAME-$stack_name"
if aws ec2 create-key-pair --key-name "$ssh_key" --output=text --query KeyMaterial > $ssh_key.pem; then
    aws s3 cp $ssh_key.pem s3://$KEY_BUCKET/$ssh_key.pem
else
    # assume the key already exists - try to re-use it
    aws s3 cp s3://$KEY_BUCKET/$ssh_key.pem $ssh_key.pem
fi
chmod 600 $ssh_key.pem
# extract a public key to make sure we actually downloaded a private key
ssh-keygen -f "$ssh_key.pem" -y < /dev/null
# clean up after ourself - jenkins jobs should re-copy key
rm -f "$ssh_key.pem"

aws cloudformation create-stack --stack-name $stack_name --disable-rollback \
    --template-url https://$ARTIFACT_BUCKET.s3.amazonaws.com/$CI_NAME/squadron/$squadron_ref/cfn-promotably.json \
    --capabilities CAPABILITY_IAM --parameters \
    $ssh_from_param \
    $environment_param \
    $db_snap \
    ParameterKey=ArtifactBucket,ParameterValue=$ARTIFACT_BUCKET \
    ParameterKey=MetaDataBucket,ParameterValue=$METADATA_BUCKET \
    ParameterKey=CiName,ParameterValue=$CI_NAME \
    ParameterKey=SquadronRef,ParameterValue=$squadron_ref \
    ParameterKey=ApiRef,ParameterValue=$api_ref \
    ParameterKey=ScribeRef,ParameterValue=$scribe_ref \
    ParameterKey=DashboardRef,ParameterValue=$dashboard_ref \
    ParameterKey=SshKey,ParameterValue=$ssh_key \
    ParameterKey=DnsName,ParameterValue=$dns_suffix

get_stack_status $stack_name
