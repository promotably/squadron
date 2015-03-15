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
    stack_name="$PROJECT-ci-$CI_BUILD_NUMBER"
else
    PROJECT='None'
    stack_name="ci-$CI_BUILD_NUMBER"
fi

if [ -z "$skip_integration_tests" ]; then
    ./super-stack-create.sh -s $stack_name $project_options -e integration -w $(curl -s http://checkip.amazonaws.com/)/32 -d job$CI_BUILD_NUMBER
fi
