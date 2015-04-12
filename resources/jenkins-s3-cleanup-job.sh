#!/bin/bash

# these should be set in the environment by our CI server
: ${ARTIFACT_BUCKET:=p_tmp}
: ${METADATA_BUCKET:=p_tmp}
: ${PUBLIC_BUCKET:=p_tmp}
: ${ARCHIVE_BUCKET:=promotably-persist}
: ${KEEP_BUILDS:=20}

aws s3 sync s3://$ARTIFACT_BUCKET/ s3://$ARCHIVE_BUCKET/ci_archive/$ARTIFACT_BUCKET/
aws s3 sync s3://$METADATA_BUCKET/ s3://$ARCHIVE_BUCKET/ci_archive/$METADATA_BUCKET/
aws s3 sync s3://$PUBLIC_BUCKET/ s3://$ARCHIVE_BUCKET/ci_archive/$PUBLIC_BUCKET/

aws s3 ls s3://$METADATA_BUCKET/validated-builds/ | grep '/$' | awk '{print $2}' | while read ci_name ; do
    ci_name=$(basename $ci_name /)
    aws s3 ls s3://$METADATA_BUCKET/validated-builds/$ci_name/ | grep '/$' | awk '{print $2}' | while read proj ; do
        proj=$(basename $proj /)
        # build list of latest builds
        aws s3 ls --recursive s3://$METADATA_BUCKET/validated-builds/$ci_name/$proj/ | tail -n $KEEP_BUILDS | awk '{print $4}' >> keep_builds
        aws s3 ls --recursive s3://$METADATA_BUCKET/validated-builds/$ci_name/$proj/ | awk '{print $4}' | while read build ; do
            # nuke metadata for old builds
            if ! fgrep -q "$build" keep_builds; then
                echo "!!! DELETE: s3://$METADATA_BUCKET/$(dirname $build)"
                aws s3 rm --recursive "s3://$METADATA_BUCKET/$(dirname $build)"
            fi
        done
        # cycle through projects, delete old build artifacts
        aws s3 ls s3://$ARTIFACT_BUCKET/$ci_name/$proj/ | awk '{print $2}' | while read gitref ; do
            gitref=$(basename $gitref /)
            if [ "$gitref" != 'latest' ] && ! grep -q "/$gitref$" keep_builds; then
                echo "!!! DELETE s3://$ARTIFACT_BUCKET/$ci_name/$proj/$gitref"
                aws s3 rm --recursive "s3://$ARTIFACT_BUCKET/$ci_name/$proj/$gitref"
            fi
        done
        # do the same for js projects in public bucket
        if [ "$proj" = 'dashboard' ]; then
            aws s3 ls s3://$PUBLIC_BUCKET/db/ | awk '{print $2}' | while read gitref ; do
                gitref=$(basename $gitref /)
                if [ "$gitref" != 'latest' ] && ! grep -q "/$gitref$" keep_builds; then
                    echo "!!! DELETE  s3://$PUBLIC_BUCKET/db/$gitref"
                    aws s3 rm --recursive "s3://$PUBLIC_BUCKET/db/$gitref"
                fi
            done
        fi
        if [ "$proj" = 'js-rco' ]; then
            aws s3 ls s3://$PUBLIC_BUCKET/js-rco/ | awk '{print $2}' | while read gitref ; do
                gitref=$(basename $gitref /)
                if [ "$gitref" != 'stable' ] && ! grep -q "/$gitref$" keep_builds; then
                    echo "!!! DELETE  s3://$PUBLIC_BUCKET/js-rco/$gitref"
                    aws s3 rm --recursive "s3://$PUBLIC_BUCKET/js-rco/$gitref"
                fi
            done
        fi
        rm -f keep_builds
    done
done
