#!/usr/bin/env bash
# Local Terraform hygiene check using the official Docker image (no local install needed):
# format, then init (no backend) + validate for each stack.
set -euo pipefail
cd "$(dirname "$0")/../terraform"
IMAGE=${TF_IMAGE:-hashicorp/terraform:1.12}
tf() { docker run --rm -v "$PWD":/w -w /w "$IMAGE" "$@"; }

echo "== fmt"
tf fmt -recursive -diff -check || { echo "run: scripts/tf-check.sh --fix"; [ "${1:-}" = "--fix" ] && tf fmt -recursive; }
[ "${1:-}" = "--fix" ] && tf fmt -recursive

for d in bootstrap envs/prod; do
  echo "== validate $d"
  tf -chdir="$d" init -backend=false -input=false -no-color >/dev/null
  tf -chdir="$d" validate -no-color
done
