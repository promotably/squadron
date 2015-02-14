#!/bin/bash

resource_dir="$(dirname $0)/../resources"
cert="$1"

if [ -z "$cert" ] || \
   [ ! -f "$resource_dir/ssl/${cert}.key" -a ! -f "$resource_dir/ssl/${cert}.crt" -a ! -f "$resource_dir/ssl/${cert}.ca-bundle" ]; then
    echo "Usage: $(basename $0) <cert>" >&2
    echo >&2
    echo "${cert}.key, ${cert}.crt, and ${cert}.ca-bundle must exist in $resource_dir/ssl" >&2
    exit 1
fi

set -ex
cd "$resource_dir/ssl"

umask 0077
tmp_key=$(mktemp)
tmp_crt=$(mktemp)
tmp_bundle=$(mktemp)

clean_up() {
    set +ex
    rm -f "$@"
    if [ -n "$EXIT_SUCCESS" ]; then
        exit 0
    fi
    exit 1
}

trap "clean_up \"$tmp_key\" \"$tmp_crt\" \"$tmp_bundle\"" SIGINT SIGTERM SIGQUIT EXIT

# copy to temp files using openssl to validate their content
openssl rsa -in "${cert}.key" -out "$tmp_key"
openssl x509 -in "${cert}.crt" -out "$tmp_crt"
if openssl x509 -in "${cert}.ca-bundle" -noout; then
    cp "${cert}.ca-bundle" "$tmp_bundle"
fi

cn=$(openssl x509 -in "$tmp_crt" -noout -subject | sed 's,^.*/CN=\([^/]\+\).*$,\1,' | sed 's/^[*][.]/wildcard-/')

start_date=$(openssl x509 -in "$tmp_crt" -noout -startdate | cut -d= -f2)
end_date=$(openssl x509 -in "$tmp_crt" -noout -enddate | cut -d= -f2)

if [ "$(uname -s)" = 'Darwin' ]; then
    start_ts="$(date -jf '%b %e %T %Y %Z' "$start_date" +%s)"
    end_ts="$(date -jf '%b %e %T %Y %Z' "$end_date" +%s)"
    date_str=$(date -r $end_ts +%Y-%m-%d )
else
    start_ts=$(date -d "$start_date" +%s)
    date_str=$(date +%Y-%m-%d -d "$end_date")
fi

aws iam upload-server-certificate --server-certificate-name "$cn-$start_ts-$date_str" \
    --private-key "file://$tmp_key" \
    --certificate-body "file://$tmp_crt" \
    --certificate-chain "file://$tmp_bundle"

EXIT_SUCCESS='yes'
