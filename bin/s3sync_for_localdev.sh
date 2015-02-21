#!/bin/bash

destbucket="$1"

if [ -z "$destbucket" ]; then
    echo "Usage: $(basename $0) <destination-bucket>" >&2
    echo >&2
    echo "WARNING: Use a dev bucket for the destination!!!" >&2
    exit 1
fi

set -ex

SRC_CI=jenkins
aws s3 sync --delete s3://promotably-build-artifacts/$SRC_CI/ s3://$destbucket/localdev/
aws s3 sync --delete s3://promotably-build-artifacts/db/ s3://$destbucket/db/
aws s3 sync --delete s3://promotably-build-metadata/validated-builds/$SRC_CI/ s3://$destbucket/validated-builds/localdev/
