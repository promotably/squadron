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
            dashboard_ref=$($awscmd s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/dashboard/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            ;;
        squadron|scribe)
            api_ref=$($awscmd s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/api/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            dashboard_ref=$($awscmd s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/dashboard/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            ;;
        dashboard)
            api_ref=$($awscmd s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/api/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            dashboard_ref=$CI_COMMIT_ID
            ;;
        metrics-aggregator)
            api_ref=$($awscmd s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/api/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            dashboard_ref=$($awscmd s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/dashboard/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
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
    # pull down dashboard sources
    $awscmd s3 cp "s3://$ARTIFACT_BUCKET/$CI_NAME/dashboard/$dashboard_ref/source.zip" dashboard-source.zip

    # dashboard integration tests
    mkdir dashboard
    cd dashboard
    unzip ../dashboard-source.zip
    npm install
    bower install
    ( ../jenkins-integration-tests-dashboard.sh "$stack_name" 2>&1 || touch ../test_failure ) \
        | tee $integration_test_results
    cd ..
fi

$awscmd s3 cp $integration_test_results "s3://$ARTIFACT_BUCKET/$CI_NAME/$PROJECT/$CI_COMMIT_ID/integration-results-dashboard.txt"

if [ -f test_failure ]; then
    exit 1
fi
exit 0
