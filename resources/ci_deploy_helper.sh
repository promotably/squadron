#!/bin/bash
 
set -ex
 
dashboard_ref=5004a8c669a3e8df4d24ec5ed4b044add2852711
api_ref=wgb-fdb760127f0d6e9f9000a2f28b1021c7a1ccfc8f
scribe_ref=vrivellino-34a19a2d3cb01bba42312245c9c2056a8806eb5c

tpl_url=https://promotably-build-artifacts.s3.amazonaws.com/squadron/latest
api_jar=api-${api_ref}-standalone.jar
api_zip=api-${api_ref}-source.zip
scribe_jar=scribe-${scribe_ref}-standalone.jar
scribe_zip=scribe-${scribe_ref}-source.zip
key_name=vince-test
sns=arn:aws:sns:us-east-1:955631477036:vince

for s3_file in $api_jar $api_zip $scribe_jar $scribe_zip db/$dashboard_ref/index.html; do
    aws s3 ls s3://promotably-build-artifacts/$s3_file > /dev/null
done
 
for tpl in promotably.json api.json network.json scribe.json ; do
    aws s3 cp $tpl s3://promotably-build-artifacts/squadron/latest/
    aws cloudformation validate-template --template-url $tpl_url/$tpl > /dev/null
done
aws s3 cp integration_test_driver.sh s3://promotably-build-artifacts/squadron/latest/run_tests.sh

if [ -n "$1" ]; then
    aws cloudformation update-stack --stack-name $1 \
        --template-url $tpl_url/promotably.json --capabilities CAPABILITY_IAM --parameters \
        ParameterKey=ApiArtifact,ParameterValue=$api_jar \
        ParameterKey=ApiZip,ParameterValue=$api_zip \
        ParameterKey=ScribeArtifact,ParameterValue=$scribe_jar \
        ParameterKey=ScribeZip,ParameterValue=$scribe_zip \
        ParameterKey=DashboardRef,ParameterValue=$dashboard_ref \
        ParameterKey=SshKey,ParameterValue=$key_name \
        ParameterKey=TestResultsSNSTopicARN,ParameterValue=$sns 

else
    aws cloudformation create-stack --stack-name vr-$(date +%s) \
        --template-url $tpl_url/promotably.json --capabilities CAPABILITY_IAM --parameters \
        ParameterKey=ApiArtifact,ParameterValue=$api_jar \
        ParameterKey=ApiZip,ParameterValue=$api_zip \
        ParameterKey=ScribeArtifact,ParameterValue=$scribe_jar \
        ParameterKey=ScribeZip,ParameterValue=$scribe_zip \
        ParameterKey=DashboardRef,ParameterValue=$dashboard_ref \
        ParameterKey=SshKey,ParameterValue=$key_name \
        ParameterKey=TestResultsSNSTopicARN,ParameterValue=$sns
fi
