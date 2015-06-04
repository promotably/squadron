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
            ;;
        squadron|scribe)
            api_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/api/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            ;;
        dashboard)
            api_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/api/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
            skip_integration_tests='true'
            ;;
        metrics-aggregator)
            api_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/api/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
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

# pull down api source and unzip locally
aws s3 cp "s3://$ARTIFACT_BUCKET/$CI_NAME/api/$api_ref/source.zip" api-source.zip
mkdir api
cd api
unzip api-source.zip

integration_test_results=$(mktemp)
echo -n > $integration_test_results
rm -f test_failure
if [ -z "$skip_integration_tests" ]; then
    ( ../jenkins-integration-tests.sh "$stack_name" 2>&1 || touch test_failure ) \
        | tee $integration_test_results
    set -x
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
