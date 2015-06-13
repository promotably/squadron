#!/bin/bash

SRC_CI=jenkins
: ${CI_NAME:=localdev}

destbucket="$1"

if [ -z "$destbucket" ]; then
    echo "Usage: $(basename $0) <destination-bucket>" >&2
    echo >&2
    echo "WARNING: Use a dev bucket for the destination!!!" >&2
    exit 1
fi

set -ex

aws s3 sync --delete s3://promotably-build-artifacts/$SRC_CI/ s3://$destbucket/$CI_NAME/
aws s3 sync --delete s3://promotably-build-metadata/validated-builds/$SRC_CI/ s3://$destbucket/validated-builds/$CI_NAME/

cd "$(dirname $0)/../resources/"
aws s3 sync --delete --exclude "ssl/*" --exclude "*.swp" ./ s3://$destbucket/$CI_NAME/squadron/dev/
