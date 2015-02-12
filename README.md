# squadron

This project is designed to deploy the Promotably application(s) into
the cloud in a repeatable, automatable way.

TODO: Update README. This is woefully out of date.

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
curl -sL --user 'cvillecsteele:githubfib0112358!' https://api.github.com/repos/promotably/dashboard/tarball/master > dashboard.tar
tar -xf squadron.tar
tar -xf dashboard.tar
rm squadron.tar
rm dashboard.tar
export DASH_REF=$(echo promotably-dashboard-* | cut -d'-' -f3)
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
cd promotably-squadron-* && ln -s ../bin/aws ./aws && lein run --github-user=cvillecsteele --github-password='githubfib0112358!' --super-stack-name=$CI_COMMITTER_USERNAME-$CI_COMMIT_ID --api-jar ../target/*standalone*jar --dashboard-ref=$DASH_REF
```

A full list of command line arguments is available in core.clj.

## TODO

* Deploy Wordpress site

## SSL Certificate

CSR was generated using following command:

```
$ openssl req -new -newkey rsa:2048 -nodes -keyout promotably.com.key -out promotably.com.csr
Generating a 2048 bit RSA private key
.............+++
...........................................................+++
writing new private key to 'promotably.com.key'
-----
You are about to be asked to enter information that will be incorporated
into your certificate request.
What you are about to enter is what is called a Distinguished Name or a DN.
There are quite a few fields but you can leave some blank
For some fields there will be a default value,
If you enter '.', the field will be left blank.
-----
Country Name (2 letter code) [AU]:US
State or Province Name (full name) [Some-State]:Virginia
Locality Name (eg, city) []:Charlottesville
Organization Name (eg, company) [Internet Widgits Pty Ltd]:Promotably, LLC
Organizational Unit Name (eg, section) []:
Common Name (e.g. server FQDN or YOUR name) []:*.promotably.com
Email Address []:

Please enter the following 'extra' attributes
to be sent with your certificate request
A challenge password []:
An optional company name []:
```

Private key was then encrypted using:

```
openssl rsa -in promotably.com.key -out promotably.com.key.enc -des3
mv promotably.com.key.enc promotably.com.key
```

Passphrase is in LastPass.

## License

Copyright © 2014 Promotably, LLC

