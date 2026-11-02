#!/usr/bin/env bash
# Runs ON the EC2 host (as root) through AWS SSM Run Command:
# roll one EduPulse component to a new container image from GHCR.
#   ssm-deploy.sh <component> <image-ref>
set -euo pipefail

component="${1:?usage: ssm-deploy.sh <component> <image-ref>}"
image="${2:?image reference required}"
version="${VERSION:-}"
region="${AWS_REGION:-eu-north-1}"
user_param="${GHCR_USER_PARAM:-/devsecops-demo/prod/ghcr_pull_user}"
token_param="${GHCR_TOKEN_PARAM:-/devsecops-demo/prod/ghcr_pull_token}"
retries="${HEALTH_RETRIES:-30}"
delay="${HEALTH_DELAY:-5}"
state_dir=/var/lib/gha-deploy
workdir="/opt/edupulse"

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

case "${component}" in
  auth-service|backend|audit-service|frontend)
    project="${COMPOSE_PROJECT:-edupulse}"
    service="${component}"
    ;;
  *) die "unknown component '${component}'" ;;
esac

image_re='^ghcr\.io/[a-z0-9._/-]+(:[A-Za-z0-9._-]+|@sha256:[a-f0-9]{64})$'
[[ "${image}" =~ ${image_re} ]] || die "refusing image reference '${image}'"
[[ -z "${version}" || "${version}" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || die "refusing version label '${version}'"

mkdir -p "${state_dir}"
override="${state_dir}/${component}.override.yml"
previous="${state_dir}/${component}.override.yml.prev"

[ -f "${workdir}/docker-compose.yml" ] || die "missing ${workdir}/docker-compose.yml"

compose() {
  local args=(-p "${project}" --project-directory "${workdir}" -f "${workdir}/docker-compose.yml")
  local comp
  for comp in auth-service backend audit-service frontend; do
    if [ "${comp}" != "${component}" ] && [ -f "${state_dir}/${comp}.override.yml" ]; then
      args+=(-f "${state_dir}/${comp}.override.yml")
    fi
  done
  [ -f "${override}" ] && args+=(-f "${override}")
  docker compose "${args[@]}" "$@"
}

ghcr_login() {
  if ! command -v aws >/dev/null 2>&1 || [ -z "${region}" ]; then
    log "no aws cli/region on host: pulling anonymously"; return 0
  fi
  local user token
  user="$(aws ssm get-parameter --region "${region}" --name "${user_param}" --query Parameter.Value --output text 2>/dev/null || true)"
  token="$(aws ssm get-parameter --region "${region}" --name "${token_param}" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)"
  if [ -n "${user}" ] && [ -n "${token}" ] && [ "${token}" != "None" ]; then
    printf '%s' "${token}" | docker login ghcr.io -u "${user}" --password-stdin >/dev/null
    log "logged in to ghcr.io as ${user}"
  else
    log "no GHCR pull credentials in SSM (${token_param}): pulling anonymously"
  fi
}

healthy() {
  case "${component}" in
    auth-service)
      curl -fsS -m 5 "http://127.0.0.1:4000/health" >/dev/null
      ;;
    backend)
      curl -fsS -m 5 "http://127.0.0.1:5000/health" >/dev/null
      ;;
    audit-service)
      curl -fsS -m 5 "http://127.0.0.1:6000/health" >/dev/null
      ;;
    frontend)
      curl -fsS -m 5 "http://127.0.0.1:80/healthz" >/dev/null
      ;;
  esac
}

wait_healthy() {
  local i
  for i in $(seq 1 "${retries}"); do
    if healthy; then return 0; fi
    log "waiting for ${component} to become healthy (${i}/${retries})"
    sleep "${delay}"
  done
  return 1
}

write_override() {
  {
    echo "# Managed by GitHub Actions deploy for ${component}"
    echo "services:"
    echo "  ${service}:"
    echo "    image: ${image}"
  } > "${override}"
}

log "component=${component} image=${image} version=${version:-n/a}"
ghcr_login

pulled=false
for attempt in 1 2 3; do
  if docker pull "${image}"; then pulled=true; break; fi
  log "pull failed (attempt ${attempt}/3), retrying..."; sleep 5
done
${pulled} || die "could not pull ${image}"

if [ -f "${override}" ]; then cp -f "${override}" "${previous}"; had_override=true; else rm -f "${previous}"; had_override=false; fi
write_override

log "recreating ${service} with the new image"
if compose up -d --no-deps --pull never "${service}" && wait_healthy; then
  log "healthy: ${component} is running ${image}"
  printf '%s %s\n' "$(date -u +%FT%TZ)" "${image}" > "${state_dir}/${component}.last-deployed"
  rm -f "${previous}"
  docker image prune -f >/dev/null 2>&1 || true
  exit 0
fi

log "new image is NOT healthy: container state and last logs follow"
compose ps "${service}" || true
compose logs --tail 40 "${service}" || true

log "rolling back"
if ${had_override}; then mv -f "${previous}" "${override}"; else rm -f "${override}" "${previous}"; fi
if compose up -d --no-deps --pull never "${service}" && wait_healthy; then
  die "deploy failed; rolled back to the previous image and it is healthy"
fi
die "deploy failed AND the rollback is not healthy: manual attention needed"
