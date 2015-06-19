#!/bin/bash

# these should be set in the environment by our CI server
: ${ARTIFACT_BUCKET:=p_tmp}
: ${METADATA_BUCKET:=p_tmp}
: ${KEY_BUCKET:=promotably-keyvault}
: ${AUTO_TERM_STACK:=true}

# Attempt to detect if we're on a dev's system
[ -n "$AWS_DEFAULT_REGION" ] || export AWS_DEFAULT_REGION=us-east-1
awscmd='aws'
if [ -f ~/.aws/credentials -a "$CI_NAME" != 'jenkins' ]; then
    awscmd="aws --profile promotably"
    unset AWS_ACCOUNT_ID AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SECRET_KEY
fi

# variables consumed by script
PROJECT="$1"
: ${CI_NAME:=localdev}
case "$CI_NAME" in
    jenkins)
        CI='true'
        CI_COMMIT_ID="$2"
        ;;
    localdev)
        CI='false'
        CI_COMMIT_ID='dev'
        ;;
esac

set -ex

if [ -z "$CI_BUILD_NUMBER" ]; then
    echo "Fatal: \$CI_BUILD_NUMBER is empty!" >&2
    exit 1
fi

if [ -n "$PROJECT" ]; then
    case "$PROJECT" in
        api)
            api_ref=$CI_COMMIT_ID
            dashboard_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/dashboard/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            ;;
        squadron|scribe)
            api_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/api/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            dashboard_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/dashboard/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            ;;
        dashboard)
            api_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/api/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            dashboard_ref=$CI_COMMIT_ID
            ;;
        metrics-aggregator)
            api_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/api/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            dashboard_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/dashboard/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            skip_integration_tests='true'
            ;;
        *)
            echo "Fatal: Unknown project $PROJECT" >&2
            exit 1
            ;;
    esac
    stack_name="$PROJECT-ci-$CI_BUILD_NUMBER"
else
    PROJECT='None'
    stack_name="ci-$CI_BUILD_NUMBER"
fi

integration_test_results=$(mktemp)
echo -n > $integration_test_results
rm -f test_failure

if [ -z "$skip_integration_tests" ]; then
    # pull down api & dashboard sources
    aws s3 cp "s3://$ARTIFACT_BUCKET/$CI_NAME/api/$api_ref/source.zip" api-source.zip
    aws s3 cp "s3://$ARTIFACT_BUCKET/$CI_NAME/dashboard/$dashboard_ref/source.zip" dashboard-source.zip

    # api integration tests
    mkdir api
    cd api
    unzip ../api-source.zip
    ( ../jenkins-integration-tests.sh "$stack_name" 2>&1 || touch ../test_failure ) \
        | tee $integration_test_results
    cd ..
    set -x

    # dashboard integration tests
    # TODO maybe do this in jenkins-integration-tests.sh?
    mkdir dashboard
    cd dashboard
    unzip ../dashboard-source.zip
    npm install
    bower install
    api_stack="$($awscmd cloudformation describe-stacks --output=text --stack-name $stack_name --query 'Stacks[0].Outputs[?OutputKey==`ApiStack`].OutputValue[]')"
    db_elb_url="$($awscmd cloudformation describe-stacks --output=text --stack-name $api_stack --query 'Stacks[0].Outputs[?OutputKey==`DashboardURL`].OutputValue[]')"
    # TODO save output in $integration_test_results
    gulp test:integration --urlroot=$db_elb_url || touch ../test_failure
    cd ..
fi


if [ -f test_failure ] || grep -q 'java.lang.[A-Za-z0-9_.-]*Exception' $integration_test_results; then
    exit 1
else
    if [ -n "$PROJECT" -a "$PROJECT" != 'None' -a -n "$CI_BUILD_NUMBER" ]; then
        touch $integration_test_results
        s3_url="s3://$METADATA_BUCKET/validated-builds/$CI_NAME/$PROJECT/$(printf '%.12d' $CI_BUILD_NUMBER)"
        aws s3 cp $integration_test_results "$s3_url/$CI_COMMIT_ID"
    fi
fi
