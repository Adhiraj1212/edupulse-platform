#!/usr/bin/env bash
# Runner side (GitHub Actions): ship scripts/ssm-deploy.sh to an EC2 instance through SSM Run Command,
# wait for it, print its output and fail if it failed.
#   AWS_REGION=... ssm-run.sh <component> <image-ref> <instance-id> [version-label]
# Needs: aws cli, jq, base64 and credentials allowed to ssm:SendCommand / ssm:GetCommandInvocation.
set -euo pipefail

component="${1:?usage: ssm-run.sh <component> <image-ref> <instance-id> [version-label]}"
image="${2:?image reference required}"
instance="${3:?instance id required}"
version="${4:-}"
region="${AWS_REGION:?AWS_REGION is required}"
script="$(dirname "${BASH_SOURCE[0]}")/ssm-deploy.sh"

image_re='^ghcr\.io/[a-z0-9._/-]+(:[A-Za-z0-9._-]+|@sha256:[a-f0-9]{64})$'
[[ "${component}" =~ ^(auth-service|backend|audit-service|frontend)$ ]] || { echo "bad component: ${component}" >&2; exit 2; }
[[ "${image}" =~ ${image_re} ]] || { echo "bad image reference: ${image}" >&2; exit 2; }
[[ "${instance}" =~ ^i-[0-9a-f]+$ ]] || { echo "bad instance id: ${instance}" >&2; exit 2; }
[[ -z "${version}" || "${version}" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || { echo "bad version label: ${version}" >&2; exit 2; }

b64="$(base64 -w0 "${script}" 2>/dev/null || base64 "${script}" | tr -d '\r\n')"
params="$(jq -cn --arg b "${b64}" --arg c "${component}" --arg i "${image}" --arg r "${region}" --arg v "${version}" \
  '{commands: ["set -euo pipefail",
               "echo \($b) | base64 -d > /tmp/ssm-deploy.sh",
               "AWS_REGION=\($r) VERSION=\($v) bash /tmp/ssm-deploy.sh \($c) \($i)"],
    executionTimeout: ["900"]}')"

cid="$(aws ssm send-command \
  --instance-ids "${instance}" \
  --document-name AWS-RunShellScript \
  --comment "github-actions deploy ${component}" \
  --timeout-seconds 120 \
  --parameters "${params}" \
  --query Command.CommandId --output text)"
echo "SSM command id: ${cid} (instance ${instance})"

deadline=$(( $(date +%s) + 1000 ))
status=Pending
while :; do
  status="$(aws ssm get-command-invocation --command-id "${cid}" --instance-id "${instance}" \
            --query Status --output text 2>/dev/null || echo Pending)"
  case "${status}" in
    Success|Failed|Cancelled|TimedOut|Cancelling) break ;;
  esac
  if [ "$(date +%s)" -ge "${deadline}" ]; then echo "timed out waiting for the SSM command" >&2; exit 1; fi
  sleep 5
done

echo "===== output (status: ${status}) ====="
aws ssm get-command-invocation --command-id "${cid}" --instance-id "${instance}" \
  --query StandardOutputContent --output text
if [ "${status}" != "Success" ]; then
  echo "===== stderr =====" >&2
  aws ssm get-command-invocation --command-id "${cid}" --instance-id "${instance}" \
    --query StandardErrorContent --output text >&2
  exit 1
fi
