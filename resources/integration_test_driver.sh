#!/bin/bash

run_tests() {
    if [ -z "$artifact_bucket" ]; then
        echo 'Fatal: $artifact_bucket is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$metadata_bucket" ]; then
        echo 'Fatal: $metadata_bucket is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$ci_name" ]; then
        echo 'Fatal: $metadata_bucket is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$build_num" ]; then
        echo 'Fatal: $metadata_bucket is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$squadron_ref" ]; then
        echo 'Fatal: $metadata_bucket is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$api_ref" ]; then
        echo 'Fatal: $metadata_bucket is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$scribe_ref" ]; then
        echo 'Fatal: $metadata_bucket is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$dashboard_ref" ]; then
        echo 'Fatal: $metadata_bucket is not set - foget to setup the environment?' >&2
        return 1
    fi

    if [ -z "$aws_region" ]; then
        echo 'Fatal: $aws_region is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$ssh_key" ]; then
        echo 'Fatal: $ssh_key is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$promotably_stack" ]; then
        echo 'Fatal: $promotably_stack is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$network_stack" ]; then
        echo 'Fatal: $network_stack is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$api_stack" ]; then
        echo 'Fatal: $api_stack is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$scribe_stack" ]; then
        echo 'Fatal: $scribe_stack is not set - foget to setup the environment?' >&2
        return 1
    fi
    if [ -z "$test_result_email" ]; then
        echo 'Fatal: $test_result_email is not set - foget to setup the environment?' >&2
        return 1
    fi

    set +x

    bastion_ip="$(aws cloudformation describe-stacks --region $aws_region --output=text --stack-name $network_stack --query 'Stacks[0].Outputs[?OutputKey==`Bastion`].OutputValue[]')"
    api_asg="$(aws cloudformation describe-stacks --region $aws_region --output=text --stack-name $api_stack --query 'Stacks[0].Outputs[?OutputKey==`APIInstanceGroup`].OutputValue[]')"
    scribe_asg="$(aws cloudformation describe-stacks --region $aws_region --output=text --stack-name $scribe_stack --query 'Stacks[0].Outputs[?OutputKey==`ScribeInstanceGroup`].OutputValue[]')"

    api_instance_id="$(aws autoscaling describe-auto-scaling-groups --region $aws_region --output=text --auto-scaling-group-names $api_asg --query 'AutoScalingGroups[0].Instances[0].InstanceId')"
    scribe_instance_id="$(aws autoscaling describe-auto-scaling-groups --region $aws_region --output=text --auto-scaling-group-names $scribe_asg --query 'AutoScalingGroups[0].Instances[0].InstanceId')"

    api_ip="$(aws ec2 describe-instances --region $aws_region --output=text --instance-ids $api_instance_id --query 'Reservations[0].Instances[0].PrivateIpAddress')"
    scribe_ip="$(aws ec2 describe-instances --region $aws_region --output=text --instance-ids $scribe_instance_id --query 'Reservations[0].Instances[0].PrivateIpAddress')"

    [ -z "$api_ip" -o -z "$scribe_ip" ] && return 1

    ssh_cmd='ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -t'

    echo "Integration Test Stack: $promotably_stack" >> integration_test_results.txt
    echo "Network Stack: $network_stack" >> integration_test_results.txt
    echo "API Stack: $api_stack" >> integration_test_results.txt
    echo "Scribe Stack: $scribe_stack" >> integration_test_results.txt
    echo >> integration_test_results.txt

    echo 'API TEST RESULTS' >> integration_test_results.txt
    echo '------------------------------------------------------------------------------' >> integration_test_results.txt
    $ssh_cmd ec2-user@$bastion_ip "$ssh_cmd $api_ip \"cd /opt/promotably/api && sudo ../api-integration-test.sh\"" >> integration_test_results.txt 2>&1 || return $?

    echo >> integration_test_results.txt
    echo >> integration_test_results.txt

    echo 'SCRIBE TEST RESULTS' >> integration_test_results.txt
    echo '------------------------------------------------------------------------------' >> integration_test_results.txt
    $ssh_cmd ec2-user@$bastion_ip "$ssh_cmd $scribe_ip \"cd /opt/promotably/scribe && sudo ../scribe-integration-test.sh\"" >> integration_test_results.txt 2>&1 || return $?

    echo >> integration_test_results.txt
    echo >> integration_test_results.txt

    echo '------------------------------------------------------------------------------' >> integration_test_results.txt

    get_stack_status() {
        timeout_ts=$((`date +%s` + 1800))
        while [ $(date +%s) -le $timeout_ts ] && sleep 10; do
            stack_status=$(aws cloudformation describe-stacks --region $aws_region --output=text --stack-name "$1" --query 'Stacks[0].StackStatus')
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
        done
        aws cloudformation describe-stacks --region $aws_region --output=text --stack-name "$1" --query 'Stacks[0].StackStatus'
        return 1
    }

    aws cloudformation update-stack --region $aws_region --stack-name $scribe_stack \
        --use-previous-template --capabilities CAPABILITY_IAM --parameters \
        ParameterKey=Environment,ParameterValue=staging \
        ParameterKey=ArtifactBucket,UsePreviousValue=true \
        ParameterKey=ArtifactPath,UsePreviousValue=true \
        ParameterKey=KeyPair,UsePreviousValue=true \
        ParameterKey=DBHost,UsePreviousValue=true \
        ParameterKey=DBPort,UsePreviousValue=true \
        ParameterKey=DBUsername,UsePreviousValue=true \
        ParameterKey=DBPassword,UsePreviousValue=true \
        ParameterKey=DBName,UsePreviousValue=true \
        ParameterKey=KinesisStreamA,UsePreviousValue=true \
        ParameterKey=KinesisStreamB,UsePreviousValue=true \
        ParameterKey=VpcId,UsePreviousValue=true \
        ParameterKey=VpcDefaultSecurityGroup,UsePreviousValue=true \
        ParameterKey=AvailabilityZones,UsePreviousValue=true \
        ParameterKey=PublicSubnets,UsePreviousValue=true || return $?

    scribe_stack_status=$(get_stack_status $scribe_stack)

    echo >> integration_test_results.txt
    echo "SCRIBE STACK STATUS AFTER UPDATE TO STAGING: $scribe_stack_status" >> integration_test_results.txt

    aws cloudformation update-stack --region $aws_region --stack-name $api_stack \
        --use-previous-template --capabilities CAPABILITY_IAM --parameters \
        ParameterKey=Environment,ParameterValue=staging \
        ParameterKey=ArtifactBucket,UsePreviousValue=true \
        ParameterKey=ArtifactPath,UsePreviousValue=true \
        ParameterKey=DashboardRef,UsePreviousValue=true \
        ParameterKey=KeyPair,UsePreviousValue=true \
        ParameterKey=DBUsername,UsePreviousValue=true \
        ParameterKey=DBPassword,UsePreviousValue=true \
        ParameterKey=DBName,UsePreviousValue=true \
        ParameterKey=DBClass,UsePreviousValue=true \
        ParameterKey=DBAllocatedStorage,UsePreviousValue=true \
        ParameterKey=VpcId,UsePreviousValue=true \
        ParameterKey=VpcDefaultSecurityGroup,UsePreviousValue=true \
        ParameterKey=NATSecurityGroup,UsePreviousValue=true \
        ParameterKey=AvailabilityZones,UsePreviousValue=true \
        ParameterKey=PublicSubnets,UsePreviousValue=true \
        ParameterKey=PrivateSubnets,UsePreviousValue=true || return $?

    api_stack_status=$(get_stack_status $api_stack)

    echo >> integration_test_results.txt
    echo "API STACK STATUS AFTER UPDATE TO STAGING: $api_stack_status" >> integration_test_results.txt
}

echo -n > integration_test_results.txt
if ! run_tests > run_tests.out 2>&1; then
    email_subject_xtra=' - FAILURE'
else
    if [ -n "$project" -a "$project" != 'None' -a "$build_num" != 'None' ]; then
        touch empty
        s3_url="s3://$metadata_bucket/validated-builds/$ci_name/$project/$(printf '%.12d' $build_num)"
        case "$project" in
            squadron) aws s3 cp empty "$s3_url/$squadron_ref" ;;
            api)      aws s3 cp empty "$s3_url/$api_ref" ;;
            scribe)   aws s3 cp empty "$s3_url/$scribe_ref" ;;
        esac
    fi
    if [ "$auto_term" = 'true' ]; then
        term_stack='true'
    fi
fi

if [ -n "$project" -a "$project" != 'None' -a "$build_num" != 'None' ]; then
    echo >> integration_test_results.txt
    s3_url="s3://$artifact_bucket/$ci_name/$project"
    case "$project" in
        squadron)
            aws s3 cp run_tests.out "$s3_url/$squadron_ref/integration-test-shell-debug.txt"
            echo "Integration test results: $s3_url/$squadron_ref/integration-test-results.txt" >> integration_test_results.txt
            echo "Integration tests shell debug output: $s3_url/$squadron_ref/integration-test-shell-debug.txt" >> integration_test_results.txt
            aws s3 cp integration_test_results.txt "$s3_url/$squadron_ref/integration-test-results.txt"
            ;;
        api)
            aws s3 cp run_tests.out "$s3_url/$api_ref/integration-test-shell-debug.txt"
            echo "Integration test results: $s3_url/$api_ref/integration-test-results.txt" >> integration_test_results.txt
            echo "Integration tests shell debug output: $s3_url/$api_ref/integration-test-shell-debug.txt" >> integration_test_results.txt
            aws s3 cp integration_test_results.txt "$s3_url/$api_ref/integration-test-results.txt"
            ;;
        scribe)
            aws s3 cp run_tests.out "$s3_url/$scribe_ref/integration-test-shell-debug.txt"
            echo "Integration test results: $s3_url/$scribe_ref/integration-test-results.txt" >> integration_test_results.txt
            echo "Integration tests shell debug output: $s3_url/$scribe_ref/integration-test-shell-debug.txt" >> integration_test_results.txt
            aws s3 cp integration_test_results.txt "$s3_url/$scribe_ref/integration-test-results.txt"
            ;;
    esac
fi


MESSAGE_ESCAPED_JSON=$(cat integration_test_results.txt)

MESSAGE_ESCAPED_JSON=${MESSAGE_ESCAPED_JSON///} # remove carriage return
MESSAGE_ESCAPED_JSON=${MESSAGE_ESCAPED_JSON//\\/\\\\} # \
#MESSAGE_ESCAPED_JSON=${MESSAGE_ESCAPED_JSON//\//\\\/} # /
#MESSAGE_ESCAPED_JSON=${MESSAGE_ESCAPED_JSON//\'/\\\'} # ' (not strictly needed ?)
MESSAGE_ESCAPED_JSON=${MESSAGE_ESCAPED_JSON//\"/\\\"} # "
MESSAGE_ESCAPED_JSON=${MESSAGE_ESCAPED_JSON//	/\\t} # \t (tab)
MESSAGE_ESCAPED_JSON=${MESSAGE_ESCAPED_JSON//
/\\\n} # \n (newline)
#MESSAGE_ESCAPED_JSON=${MESSAGE_ESCAPED_JSON//^L/\\\f} # \f (form feed)
#MESSAGE_ESCAPED_JSON=${MESSAGE_ESCAPED_JSON//^H/\\\b} # \b (backspace)

cat << _END_ > "ses-message.json"
{
    "Subject": {
        "Data": "$project/$ci_name/$build_num - Integration Test Results${email_subject_xtra}",
        "Charset": "UTF-8"
    },
    "Body": {
        "Text": {
            "Data": "$MESSAGE_ESCAPED_JSON",
            "Charset": "UTF-8"
        }
    }
}
_END_

cat << _END_ > "ses-destination.json"
{
    "ToAddresses": ["$test_result_email"]
}
_END_

aws ses send-email --region $aws_region --from integration-tests@promotably.com --destination file://ses-destination.json --message file://ses-message.json
if [ "$term_stack" = 'true' ]; then
    aws cloudformation delete-stack --region $aws_region --stack-name "$promotably_stack"
    aws ec2 delete-key-pair --region $aws_region --key-name "$ssh_key"
fi
