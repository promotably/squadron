# ops

A Clojure library designed to ... well, that part is up to you.

## Usage

Codeship.io custom deploy script contents:

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
cd promotably-squadron-* && ln -s ../bin/aws ./aws && lein run --github-username=cvillecsteele --github-password='githubfib0112358!' --super-stack-name=$CI_COMMITTER_USERNAME-$CI_COMMIT_ID

## License

Copyright © 2014 FIXME

Distributed under the Eclipse Public License either version 1.0 or (at
your option) any later version.
