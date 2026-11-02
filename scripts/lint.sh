#!/usr/bin/env bash
# Runs the same static checks CI runs, via Docker: workflows, shell scripts, Terraform security.
cd "$(dirname "$0")/.." || exit 1
rc=0
echo "== actionlint"
docker run --rm -v "$PWD":/r -w /r rhysd/actionlint:latest -color .github/workflows/*.yml || rc=1
echo "== shellcheck (warnings and above)"
docker run --rm -v "$PWD":/r -w /r koalaman/shellcheck:stable --severity=warning \
  scripts/*.sh infra/db/init.sh terraform/modules/data-host/deploy-infra.sh || rc=1
echo "== tflint (includes the required-tags rule)"
docker run --rm -v "$PWD/terraform":/data -w /data --entrypoint sh ghcr.io/terraform-linters/tflint:latest   -c "tflint --init >/dev/null && tflint --recursive" || rc=1
echo "== checkov"
docker run --rm -v "$PWD/terraform":/tf -w /tf bridgecrew/checkov:latest \
  --config-file /tf/.checkov.yaml -d /tf || rc=1
exit $rc
