#!/bin/bash

: ${CI_NAME:=localdev}
: ${KEY_BUCKET:=promotably-keyvault}

print_usage() {
    set +ex
    cat >&2 << _END_
Usage: $(basename $0) -p <project> -b <build_num> [-i]

Options:
    -p <project>        Which project to override 'known-good' version
    -b <build_num>      Upstream job build number
    -i                  Ignore errors
_END_

    if [ -n "$1" ]; then
        exit $1
    fi
}

project=''
build_num=''
ignore_err=''
opts='p:b:i'
while getopts "$opts" opt; do
    case "$opt" in
        h) print_usage 0;;
        p) project="$OPTARG" ;;
        b) build_num="$OPTARG" ;;
        i) ignore_err='true' ;;
        \?) print_usage 1;;
    esac
done

[ -n "$project" -a -n "$build_num" ] || print_usage 1

no_stack=''
case "$project" in
    squadron|api|dashboard|scribe)
        ;;
    metrics-aggregator)
        echo "$project shouldn't have a stack ... exiting quietly"
        exit 0
        ;;
    *)
        echo "Fatal: Unknown project $project" >&2
        exit 1
        ;;
esac

if ! echo "$build_num" | grep -q '^[0-9]\+$'; then
    echo "Fatal: build number $build_num is not a number" >&2
    exit 1
fi

error() {
    echo "$@" >&2
    [ -n "$ignore_err" ] || exit 1
}

error_exit() {
    echo "$@" >&2
    exit 1
}

stack_status="$(aws cloudformation describe-stacks --stack-name ${project}-ci-${build_num} --query 'Stacks[].StackStatus' --output=text)"

if [ -z "$stack_status" ]; then
    error "WARNING: Stack ${project}-ci-${build_num} does not exist"
else
    case "$stack_status" in
        DELETE_COMPLETE)
            ;;
        CREATE_COMPLETE|ROLLBACK_COMPLETE|ROLLBACK_FAILED|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE|UPDATE_ROLLBACK_FAILED|DELETE_FAILED)
            aws cloudformation delete-stack --stack-name ${project}-ci-${build_num}
            timeout_ts=$((`date +%s` + 3600))
            while [ -n "$stack_status" -a "$stack_status" != 'DELETE_COMPLETE' ]; do
                if [ $(date +%s) -gt $timeout_ts ]; then
                    error_exit "Fatal: Stack ${project}-ci-${build_num} failed to delete before timeout"
                fi

                sleep 30
                stack_status="$(aws cloudformation describe-stacks --stack-name ${project}-ci-${build_num} --query 'Stacks[].StackStatus' --output=text)"
                if [ "$stack_status" = 'DELETE_FAILED' ]; then
                    error_exit "Fatal: Stack ${project}-ci-${build_num} failed to delete"
                fi
            done
            ;;
        *)
            error_exit "Fatal: Stack ${project}-ci-${build_num} is not in a deletable state"
            ;;
    esac
fi

ddb_tables=$(aws dynamodb list-tables --query TableNames --output=text | grep -o "\<${project}-ci-${build_num}-Scribe-[0-9A-Za-z]\+\>")
[ -n "$ddb_tables" ] || error "WARNING: No DynamoDB tables found!"

rds_snaps=$(aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier' --output text | grep -o "\<${project}-ci-${build_num}-rds-[^ 	]\+\>")
[ -n "$rds_snaps" ] || error "WARNING: No RDS snapshots found!"

ec2_snaps=$(aws ec2 describe-snapshots --filters "Name=tag:Name,Values=${project}-ci-${build_num}-Jenkins-*" --query 'Snapshots[].SnapshotId' --output=text)
[ -n "$ec2_snaps" ] || error "WARNING: No EC2 snapshots found!"

ssh_key="$CI_NAME-${project}-ci-${build_num}"

# wait for resources to be available
timeout_ts=$((`date +%s` + 1800))

for ddbtable in $ddb_tables ; do
    if [ "$(aws dynamodb describe-table --table-name $ddbtable --query 'Table.TableStatus' --output=text)" != 'ACTIVE' ]; then
        sleep 30
    fi
    [ $(date +%s) -le $timeout_ts ] || error_exit "ERROR: timeout exceeded waiting for $ddbtable to be ACTIVE"
done

for dbsnap in $rds_snaps ; do
    if [ "$(aws rds describe-db-snapshots --db-snapshot-identifier $dbsnap --query 'DBSnapshots[0].Status' --output=text)" != 'available' ]; then
        sleep 30
    fi
    [ $(date +%s) -le $timeout_ts ] || error_exit "ERROR: timeout exceeded waiting for $dbsnap to be available"
done

for snap in $ec2_snaps ; do
    if [ "$(aws ec2 describe-snapshots --snapshot-ids $snap --query 'Snapshots[0].State' --output=text)" != 'completed' ]; then
        sleep 30
    fi
    [ $(date +%s) -le $timeout_ts ] || error_exit "ERROR: timeout exceeded waiting for $snap to be completed"
done

set -x
aws ec2 delete-key-pair --key-name "$ssh_key"
aws s3 rm "s3://$KEY_BUCKET/$ssh_key.pem"

for ddbtable in $ddb_tables ; do
    aws dynamodb delete-table --table-name $ddbtable
done

for dbsnap in $rds_snaps ; do
    aws rds delete-db-snapshot --db-snapshot-identifier $dbsnap
done

for ec2snap in $ec2_snaps ; do
    aws ec2 delete-snapshot --snapshot-id $ec2snap
done
