#!/bin/bash
# Pull the latest infra/ from S3, render .env from Secrets Manager, (re)start the stack.
# Run on the host by the infra pipeline through SSM:  /opt/edupulse/deploy-infra.sh
set -euo pipefail
. /opt/edupulse/instance.env
cd /opt/edupulse

aws s3 sync "s3://$BUCKET/infra/" infra/ --delete --exclude ".env" --region "$REGION"

umask 077
aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region "$REGION" \
  --query SecretString --output text \
  | jq -r 'to_entries[] | "\(.key)=\(.value)"' > infra/.env
echo "BIND_IP=$BIND_IP" >> infra/.env

cd infra
docker compose pull --quiet
docker compose up -d --remove-orphans
docker compose ps
