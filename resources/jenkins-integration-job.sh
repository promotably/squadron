#!/bin/bash

# these should be set in the environment by our CI server
: ${ARTIFACT_BUCKET:=p_tmp}
: ${METADATA_BUCKET:=p_tmp}
: ${KEY_BUCKET:=promotably-keyvault}
: ${AUTO_TERM_STACK:=true}

# variables consumed by script
PROJECT="$1"
: ${CI_NAME:=localdev}
case "$CI_NAME" in
    jenkins)
        CI='true'
        CI_BUILD_NUMBER="$BUILD_NUMBER"
        CI_COMMIT_ID="$2"
        ;;
    localdev)
        CI='false'
        CI_BUILD_NUMBER="$(date +%s)"
        CI_COMMIT_ID='dev'
        ;;
esac

## CODESHIP populates these
#CI true
#CI_BUILD_NUMBER ID of the build in our service
#CI_BUILD_URL URL of the build
#CI_PULL_REQUEST false
#CI_BRANCH Branch of the build
#CI_COMMIT_ID Commit Hash of the build
#CI_COMMITTER_NAME Name of the committer
#CI_COMMITTER_EMAIL Email of the committer
#CI_COMMITTER_USERNAME Username of the commiter in their SCM service
#CI_MESSAGE Message of the last commit for that build
#CI_NAME codeship

# helper function to wait for stack creation/update
get_stack_status() {
    set +x
    timeout_ts=$((`date +%s` + 1800))
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

if [ -n "$PROJECT" ]; then
    case "$PROJECT" in
        squadron)
            squadron_ref=$CI_COMMIT_ID
            ;;
        api)
            api_ref=$CI_COMMIT_ID
            ;;
        scribe)
            scribe_ref=$CI_COMMIT_ID
            ;;
        dashboard)
            dashboard_ref=$CI_COMMIT_ID
            skip_integration_tests='true'
            ;;
        *)
            echo "Fatal: Unknown project $PROJECT" >&2
            exit 1
            ;;
    esac
    stack_name="$PROJECT-$CI_COMMIT_ID"
    if [ "$CI_COMMIT_ID" = 'dev' ]; then
        stack_name="$PROJECT-$(date +%s)"
    fi
else
    PROJECT='None'
    stack_name="$CI_COMMIT_ID"
    if [ "$CI_COMMIT_ID" = 'dev' ]; then
        stack_name="$(date +%s)"
    fi
fi

# The autogenerated stack names are too long for Route53 records
dns_name="$(echo $stack_name | openssl md5 | awk '{print $2}')"

# Override email for local dev
email_param=''
if [ "$CI_NAME" = 'localdev' ]; then
    email_param="ParameterKey=TestResultsEmail,ParameterValue=$CI_COMMITTER_EMAIL"
fi

# validate cfn templates
aws s3 ls "https://$ARTIFACT_BUCKET.s3.amazonaws.com/$CI_NAME/squadron/$squadron_ref/" \
  | awk '{print $4}' | grep '^cfn-.*[.]json$' | while read cfn_json; do
    aws cloudformation validate-template --output=text \
        --template-url "https://$ARTIFACT_BUCKET.s3.amazonaws.com/$CI_NAME/squadron/$squadron_ref/$cfn_json"
done

# make sure other build artifacts are there
for s3_file in dashboard/$dashboard_ref/index.html api/$api_ref/standalone.jar api/$api_ref/source.zip api/$api_ref/apid \
               scribe/$scribe_ref/standalone.jar scribe/$scribe_ref/source.zip scribe/$scribe_ref/scribed ; do
    aws s3 ls s3://$ARTIFACT_BUCKET/$CI_NAME/$s3_file > /dev/null
done

echo -n > integration_test_results.txt
if [ -z "$skip_integration_tests" ]; then
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

    aws cloudformation create-stack --stack-name $stack_name --disable-rollback \
        --template-url https://$ARTIFACT_BUCKET.s3.amazonaws.com/$CI_NAME/squadron/$squadron_ref/cfn-promotably.json \
        --capabilities CAPABILITY_IAM --parameters \
        $email_param \
        ParameterKey=ArtifactBucket,ParameterValue=$ARTIFACT_BUCKET \
        ParameterKey=MetaDataBucket,ParameterValue=$METADATA_BUCKET \
        ParameterKey=Project,ParameterValue=$PROJECT \
        ParameterKey=CiName,ParameterValue=$CI_NAME \
        ParameterKey=BuildNum,ParameterValue=$CI_BUILD_NUMBER \
        ParameterKey=SquadronRef,ParameterValue=$squadron_ref \
        ParameterKey=ApiRef,ParameterValue=$api_ref \
        ParameterKey=ScribeRef,ParameterValue=$scribe_ref \
        ParameterKey=DashboardRef,ParameterValue=$dashboard_ref \
        ParameterKey=SshKey,ParameterValue=$ssh_key \
        ParameterKey=DnsName,ParameterValue=$dns_name \
        ParameterKey=SSHFrom,ParameterValue=$(curl http://checkip.amazonaws.com/)/32

    get_stack_status $stack_name

    ( ./jenkins-integration-tests.sh "$stack_name" "$ssh_key.pem" 2>&1 || touch test_failure ) \
        | tee integration_test_results.txt
    set -x
else
    AUTO_TERM_STACK=false
fi

if [ -f test_failure ] || grep -q 'java.lang.[A-Za-z0-9_.-]*Exception' integration_test_results.txt; then
    exit 1
else
    if [ -n "$PROJECT" -a "$PROJECT" != 'None' -a -n "$CI_BUILD_NUMBER" ]; then
        touch empty
        s3_url="s3://$METADATA_BUCKET/validated-builds/$CI_NAME/$PROJECT/$(printf '%.12d' $CI_BUILD_NUMBER)"
        case "$PROJECT" in
            squadron)  aws s3 cp empty "$s3_url/$squadron_ref" ;;
            api)       aws s3 cp empty "$s3_url/$api_ref" ;;
            scribe)    aws s3 cp empty "$s3_url/$scribe_ref" ;;
            dashboard) aws s3 cp empty "$s3_url/$dashboard_ref" ;;
        esac
    fi
    if [ "$AUTO_TERM_STACK" = 'true' ]; then
        aws cloudformation delete-stack --stack-name "$stack_name"
        aws ec2 delete-key-pair --key-name "$ssh_key"
        aws s3 rm "s3://$KEY_BUCKET/$ssh_key.pem"
    fi
fi
