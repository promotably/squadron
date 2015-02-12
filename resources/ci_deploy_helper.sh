#!/bin/bash

# these should be set in the environment by our CI server
: ${ARTIFACT_BUCKET:=p_tmp}
: ${METADATA_BUCKET:=p_tmp}
: ${KEY_BUCKET:=promotably-keyvault}

# variables automatically setup by CodeShip
# defaults for dev
: ${CI:=false}
: ${CI_BUILD_NUMBER:=$(date +%s)}
: ${CI_BRANCH:=$(git symbolic-ref --short -q HEAD)}
: ${CI_COMMIT_ID:=dev}
: ${CI_COMMITTER_NAME:=$(git config --get user.name)}
: ${CI_COMMITTER_EMAIL:=$(git config --get user.email)}
: ${CI_COMMITTER_USERNAME:=$(whoami)}
: ${CI_NAME:=localdev}

PROJECT="$1"

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

squadron_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/squadron/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
api_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/api/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)
scribe_ref=$(aws s3 ls --output=text --recursive s3://$METADATA_BUCKET/validated-builds/$CI_NAME/scribe/ | tail -n 1 | awk '{print $4}' | cut -f 5 -d /)

if [ -n "$PROJECT" ]; then
    # if we're in CI, drop the commit message in an object
    if [ "CI" = 'true' -a -n "$CI_MESSAGE" ]; then
        echo "$CI_MESSAGE" > "$CI_COMMITTER_USERNAME"
        aws s3 cp "$CI_COMMITTER_USERNAME" "s3://$ARTIFACT_BUCKET/$CI_NAME/$PROJECT/$CI_COMMIT_ID"
        rm -f "$CI_COMMITTER_USERNAME"
    fi

    case "$PROJECT" in
        squadron)
            # if we're dev, clear out S3 location
            if [ "$CI" = 'false' -a "$CI_COMMIT_ID" = 'dev' ]; then
                aws s3 rm --recursive "s3://$ARTIFACT_BUCKET/$CI_NAME/$PROJECT/$CI_COMMIT_ID"
            fi

            squadron_ref=$CI_COMMIT_ID
            aws s3 sync "$(dirname $0)/../resources/" "s3://$ARTIFACT_BUCKET/$CI_NAME/squadron/$squadron_ref/"
            ;;
        api)
            api_ref=$CI_COMMIT_ID
            lein uberjar
            git archive --format=zip -o target/api.zip $api_ref
            aws s3 cp target/*standalone*jar "s3://$ARTIFACT_BUCKET/$CI_NAME/api/$api_ref/standalone.jar"
            aws s3 cp target/api.zip "s3://$ARTIFACT_BUCKET/$CI_NAME/api/$api_ref/source.zip"
            aws s3 cp resources/apid "s3://$ARTIFACT_BUCKET/$CI_NAME/api/$api_ref/apid"
            ;;
        scribe)
            scribe_ref=$CI_COMMIT_ID
            lein uberjar
            git archive --format=zip -o target/scribe.zip $scribe_ref
            aws s3 cp target/*standalone*jar "s3://$ARTIFACT_BUCKET/$CI_NAME/scribe/$scribe_ref/standalone.jar"
            aws s3 cp target/scribe.zip "s3://$ARTIFACT_BUCKET/$CI_NAME/scribe/$scribe_ref/source.zip"
            aws s3 cp resources/scribed "s3://$ARTIFACT_BUCKET/$CI_NAME/scribe/$scribe_ref/scribed"
            ;;
        *)
            echo "Fatal: Unknown project $PROJECT" >&2
            exit 1
            ;;
    esac
    stack_name="$CI_COMMITTER_USERNAME-$PROJECT-$CI_COMMIT_ID"
    if [ "$CI_COMMIT_ID" = 'dev' ]; then
        stack_name="$CI_COMMITTER_USERNAME-$PROJECT-$(date +%s)"
    fi
else
    PROJECT='None'
    stack_name="$CI_COMMITTER_USERNAME-$CI_COMMIT_ID"
    if [ "$CI_COMMIT_ID" = 'dev' ]; then
        stack_name="$CI_COMMITTER_USERNAME-$(date +%s)"
    fi
fi

# validate cfn templates
for cfn in integration-test network api scribe ; do
    aws cloudformation validate-template --output=text \
        --template-url "https://$ARTIFACT_BUCKET.s3.amazonaws.com/$CI_NAME/squadron/$squadron_ref/cfn-${cfn}.json"
done

# TODO add dashboard_ref to this list
# make sure other build artifacts are there
for s3_file in api/$api_ref/standalone.jar api/$api_ref/source.zip api/$api_ref/apid \
               scribe/$scribe_ref/standalone.jar scribe/$scribe_ref/source.zip scribe/$scribe_ref/scribed ; do
    aws s3 ls s3://$ARTIFACT_BUCKET/$CI_NAME/$s3_file > /dev/null
done

ssh_key="$CI_NAME-$stack_name"
if aws ec2 create-key-pair --key-name "$ssh_key" --output=text --query KeyMaterial > $ssh_key.pem; then
    aws s3 cp $ssh_key.pem s3://$KEY_BUCKET/$ssh_key.pem
fi
rm -f $ssh_key.pem

aws cloudformation create-stack --stack-name $stack_name --disable-rollback \
    --template-url https://$ARTIFACT_BUCKET.s3.amazonaws.com/$CI_NAME/squadron/$squadron_ref/cfn-integration-test.json \
    --capabilities CAPABILITY_IAM --parameters \
    ParameterKey=ArtifactBucket,ParameterValue=$ARTIFACT_BUCKET \
    ParameterKey=MetaDataBucket,ParameterValue=$METADATA_BUCKET \
    ParameterKey=Project,ParameterValue=$PROJECT \
    ParameterKey=CiName,ParameterValue=$CI_NAME \
    ParameterKey=BuildNum,ParameterValue=$CI_BUILD_NUMBER \
    ParameterKey=SquadronRef,ParameterValue=$squadron_ref \
    ParameterKey=ApiRef,ParameterValue=$api_ref \
    ParameterKey=ScribeRef,ParameterValue=$scribe_ref \
    ParameterKey=SshKey,ParameterValue=$ssh_key
