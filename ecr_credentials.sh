#!/usr/bin/env bash

mkdir ~/.aws

cat > ~/.aws/config << EOL
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
[default]
region = us-west-2
EOL