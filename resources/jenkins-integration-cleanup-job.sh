#!/bin/bash

: ${CI_NAME:=localdev}
: ${KEY_BUCKET:=promotably-keyvault}

print_usage() {
    set +ex
    cat >&2 << _END_
Usage: $(basename $0) -p <project> -r <commit_sha> [-i]

Options:
    -p <project>        Which project to override 'known-good' version
    -r <commit_sha>     Commit sha of project (required if -p specified)
    -i                  Ignore errors
_END_

    if [ -n "$1" ]; then
        exit $1
    fi
}

project=''
gitref=''
ignore_err=''
opts='p:r:i'
while getopts "$opts" opt; do
    #echo "OPT: $opt"
    case "$opt" in
        h) print_usage 0;;
        p) project="$OPTARG" ;;
        r) gitref="$OPTARG" ;;
        i) ignore_err='true' ;;
        \?) print_usage 1;;
    esac
done

[ -n "$project" -a -n "$gitref" ] || print_usage 1

case "$project" in
    squadron|api|scribe|dashboard|metrics-aggregator)
        ;;
    *)
        echo "Fatal: Unknown project $project" >&2
        exit 1
        ;;
esac

if ! echo "$gitref" | grep -q '^\([0-9]\{10,\}\|[0-9a-f]\{40\}\)$'; then
    echo "Fatal: commit_sha '$gitref' does not follow known format" >&2
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

stack_status="$(aws cloudformation describe-stacks --stack-name $project-$gitref --query 'Stacks[].StackStatus' --output=text 2>/dev/null)"
[ -z "$stack_status" ] || error_exit "Fatal: stack $project-$gitref still exists!"

ddb_tables=$(aws dynamodb list-tables --query TableNames --output=text | grep -o "\<$project-$gitref-Scribe-[0-9A-Za-z]\+\>")
[ -n "$ddb_tables" ] || error "No DynamoDB tables found!"

rds_snaps=$(aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier' --output text | grep -o "\<$project-$gitref-rds-[^ 	]\+\>")
[ -n "$rds_snaps" ] || error "No RDS snapshots found!"

ec2_snaps=$(aws ec2 describe-snapshots --filters "Name=tag:Name,Values=$project-$gitref-Jenkins-*" --query 'Snapshots[].SnapshotId' --output=text)
[ -n "$ec2_snaps" ] || error "No EC2 snapshots found!"

ssh_key="$CI_NAME-$project-$gitref"

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
echo aws ec2 delete-key-pair --key-name "$ssh_key"
echo aws s3 rm "s3://$KEY_BUCKET/$ssh_key.pem"

for ddbtable in $ddb_tables ; do
    aws dynamodb delete-table --table-name $ddbtable
done

for dbsnap in $rds_snaps ; do
    aws rds delete-db-snapshot --db-snapshot-identifier $dbsnap
done

for ec2snap in $ec2_snaps ; do
    aws ec2 delete-snapshot --snapshot-id $ec2snap
done
