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

set -ex

project_options=''

if [ -n "$PROJECT" ]; then
    case "$PROJECT" in
        squadron)
            project_options="-p squadron -r $CI_COMMIT_ID"
            ;;
        api)
            project_options="-p api -r $CI_COMMIT_ID"
            ;;
        scribe)
            project_options="-p scribe -r $CI_COMMIT_ID"
            ;;
        dashboard)
            project_options="-p dashboard -r $CI_COMMIT_ID"
            skip_integration_tests='true'
            ;;
        metrics-aggregator)
            project_options="-p metrics-aggregator -r $CI_COMMIT_ID"
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

echo -n > integration_test_results.txt
if [ -z "$skip_integration_tests" ]; then

    ./super-stack-create.sh -s $stack_name $project_options -e integration -w $(curl -s http://checkip.amazonaws.com/)/32

    ssh_key=$(aws cloudformation describe-stacks --stack-name $stack_name \
        --output=text --query 'Stacks[0].Parameters[?ParameterKey==`SshKey`].ParameterValue')
    aws s3 cp "s3://$KEY_BUCKET/$ssh_key.pem" ./
    chmod 600 "$ssh_key.pem"

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
        aws s3 cp empty "$s3_url/$CI_COMMIT_ID"
    fi
    if [ "$AUTO_TERM_STACK" = 'true' ]; then
        aws cloudformation delete-stack --stack-name "$stack_name"
        aws ec2 delete-key-pair --key-name "$ssh_key"
        aws s3 rm "s3://$KEY_BUCKET/$ssh_key.pem"
    fi
fi
