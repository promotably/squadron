# squadron

This project is designed to deploy the Promotably application(s) into
the cloud in a repeatable, automatable way.

## Theory of operations

Leverage Cloudformation.  We maintain several inter-related stacks:

* network
* api
* ???

All of the stacks depend on network.  Some stacks depend on other
stacks, to boot.  Squadron deploys these in order, collecting info
from each deployment to pass to dependent stacks.

## Usage

You can do a deploy via the command line, but in general, this is
intended to be run via Codeship.io custom deploy script:

```
lein uberjar
curl -sL --user 'cvillecsteele:githubfib0112358!' https://api.github.com/repos/promotably/squadron/tarball/master > squadron.tar
tar -xf squadron.tar
rm squadron.tar
export PATH=.:$PATH
export AWS_ACCESS_KEY_ID=AKIAJUYKJU5POOICSK7Q
export AWS_SECRET_ACCESS_KEY=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
wget https://s3.amazonaws.com/aws-cli/awscli-bundle.zip
unzip awscli-bundle.zip
mkdir ./bin
./awscli-bundle/install -b ./bin/aws
./bin/aws s3 cp target/*standalone*jar s3://promotably-build-artifacts/api-$CI_COMMITTER_USERNAME-$CI_COMMIT_ID-standalone.jar
./bin/aws s3 cp resources/apid s3://promotably-build-artifacts/apid-$CI_COMMITTER_USERNAME-$CI_COMMIT_ID
./bin/aws s3 cp resources/apid s3://promotably-build-artifacts/apid
cd promotably-squadron-* && ln -s ../bin/aws ./aws && lein run --github-user=cvillecsteele --github-password='githubfib0112358!' --super-stack-name=$CI_COMMITTER_USERNAME-$CI_COMMIT_ID --api-jar ../target/*standalone*jar
```

A full list of command line arguments is available in core.clj.

## TODO

* Deploy pagify
* Deploy Wordpress site
* AWS CodeDeploy integration?

## License

Copyright © 2014 Promotably, LLC

