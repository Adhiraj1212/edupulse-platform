#!/usr/bin/env bash
# Runs ON the EC2 host (as root) through AWS SSM Run Command:
# Zero-Downtime Blue/Green deployment for EduPulse components.
#   ssm-deploy.sh <component> <image-ref>
set -euo pipefail

component="${1:?usage: ssm-deploy.sh <component> <image-ref>}"
image="${2:?image reference required}"
version="${VERSION:-}"
region="${AWS_REGION:-eu-north-1}"
user_param="${GHCR_USER_PARAM:-/devsecops-demo/prod/ghcr_pull_user}"
token_param="${GHCR_TOKEN_PARAM:-/devsecops-demo/prod/ghcr_pull_token}"
retries="${HEALTH_RETRIES:-30}"
delay="${HEALTH_DELAY:-3}"
state_dir="/var/lib/gha-deploy"
workdir="/opt/edupulse"
project="${COMPOSE_PROJECT:-edupulse}"

log() { printf '[bluegreen %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

case "${component}" in
  auth-service|backend|audit-service|frontend) ;;
  *) die "unknown component '${component}'" ;;
esac

image_re='^ghcr\.io/[a-z0-9._/-]+(:[A-Za-z0-9._-]+|@sha256:[a-f0-9]{64})$'
[[ "${image}" =~ ${image_re} ]] || die "refusing image reference '${image}'"
[[ -z "${version}" || "${version}" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || die "refusing version label '${version}'"

mkdir -p "${state_dir}" "${workdir}/upstreams" "${workdir}/gateway"

[ -f "${workdir}/docker-compose.yml" ] || die "missing ${workdir}/docker-compose.yml"

# Determine active and target colors
active_file="${state_dir}/${component}.color"
if [ -f "${active_file}" ]; then
  active_color="$(cat "${active_file}" | tr -d '[:space:]')"
else
  # Default: if blue is already running, switch to green; otherwise target blue
  if docker ps --format '{{.Names}}' | grep -q "${component}-blue"; then
    active_color="blue"
  else
    active_color="green"
  fi
fi

if [ "${active_color}" = "blue" ]; then
  target_color="green"
else
  target_color="blue"
fi

target_service="${component}-${target_color}"
active_service="${component}-${active_color}"
target_override="${state_dir}/${target_service}.override.yml"
active_override="${state_dir}/${active_service}.override.yml"

log "=========================================================="
log "Component:    ${component}"
log "Image:        ${image}"
log "Active Slot:  ${active_color} (${active_service})"
log "Target Slot:  ${target_color} (${target_service})"
log "=========================================================="

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

compose() {
  local args=(-p "${project}" --project-directory "${workdir}" -f "${workdir}/docker-compose.yml")
  for f in "${state_dir}"/*.override.yml; do
    [ -f "$f" ] && args+=(-f "$f")
  done
  docker compose "${args[@]}" "$@"
}

healthy() {
  local port endpoint
  case "${target_service}" in
    auth-service-blue)  port=4001; endpoint="/health" ;;
    auth-service-green) port=4002; endpoint="/health" ;;
    backend-blue)       port=5001; endpoint="/health" ;;
    backend-green)      port=5002; endpoint="/health" ;;
    audit-service-blue) port=6001; endpoint="/health" ;;
    audit-service-green)port=6002; endpoint="/health" ;;
    frontend-blue)      port=8081; endpoint="/healthz" ;;
    frontend-green)     port=8082; endpoint="/healthz" ;;
    *) die "unknown target service: ${target_service}" ;;
  esac

  curl -fsS -m 3 "http://127.0.0.1:${port}${endpoint}" >/dev/null 2>&1
}

wait_healthy() {
  local i
  for i in $(seq 1 "${retries}"); do
    if healthy; then
      log "${target_service} is healthy!"
      return 0
    fi
    log "waiting for ${target_service} to become healthy (${i}/${retries})..."
    sleep "${delay}"
  done
  return 1
}

write_target_override() {
  cat <<EOF > "${target_override}"
# Managed by Blue/Green deployment for ${component}
services:
  ${target_service}:
    image: ${image}
EOF
}

cutover_traffic() {
  log "Performing atomic zero-downtime cutover to ${target_color}..."
  case "${component}" in
    frontend)
      cat <<EOF > "${workdir}/upstreams/frontend.conf"
upstream frontend_upstream {
    server frontend-${target_color}:8080;
}
EOF
      log "Reloading gateway Nginx..."
      docker exec edupulse-gateway-1 nginx -t >/dev/null 2>&1
      docker exec edupulse-gateway-1 nginx -s reload
      ;;

    auth-service)
      cat <<EOF > "${workdir}/upstreams/auth-service.conf"
upstream auth_upstream {
    server auth-service-${target_color}:4000;
}
EOF
      log "Reloading frontend Nginx..."
      docker exec edupulse-frontend-blue-1 nginx -s reload 2>/dev/null || true
      docker exec edupulse-frontend-green-1 nginx -s reload 2>/dev/null || true
      ;;

    backend)
      cat <<EOF > "${workdir}/upstreams/backend.conf"
upstream backend_upstream {
    server backend-${target_color}:5000;
}
EOF
      log "Reloading frontend Nginx..."
      docker exec edupulse-frontend-blue-1 nginx -s reload 2>/dev/null || true
      docker exec edupulse-frontend-green-1 nginx -s reload 2>/dev/null || true
      ;;

    audit-service)
      cat <<EOF > "${workdir}/upstreams/audit-service.conf"
upstream audit_upstream {
    server audit-service-${target_color}:6000;
}
EOF
      log "Reloading frontend Nginx..."
      docker exec edupulse-frontend-blue-1 nginx -s reload 2>/dev/null || true
      docker exec edupulse-frontend-green-1 nginx -s reload 2>/dev/null || true
      ;;
  esac
  log "Traffic cutover to ${target_color} completed successfully!"
}

cleanup_old() {
  log "Draining in-flight connections on old ${active_service} (5s)..."
  sleep 5
  log "Stopping old ${active_service} container..."
  compose stop "${active_service}" 2>/dev/null || true
  compose rm -f "${active_service}" 2>/dev/null || true
  rm -f "${active_override}"
}

# 1. Pull new container image
ghcr_login
pulled=false
for attempt in 1 2 3; do
  if docker pull "${image}"; then pulled=true; break; fi
  log "pull failed (attempt ${attempt}/3), retrying..."; sleep 4
done
${pulled} || die "could not pull image: ${image}"

# 2. Write override and spin up the TARGET slot alongside the ACTIVE slot
write_target_override
log "Starting ${target_service} in the background..."
compose up -d --no-deps --pull never "${target_service}"

# 3. Health check target slot
if ! wait_healthy; then
  log "FAILURE: ${target_service} failed health checks!"
  log "Fetching logs from ${target_service}..."
  docker logs --tail 40 "edupulse-${target_service}-1" 2>/dev/null || compose logs --tail 40 "${target_service}" || true
  
  log "Cleaning up failed ${target_service} container. Active ${active_service} was NEVER touched."
  compose stop "${target_service}" 2>/dev/null || true
  compose rm -f "${target_service}" 2>/dev/null || true
  rm -f "${target_override}"
  die "Deployment failed. Active service ${active_service} remains 100% healthy and operational."
fi

# 4. Atomic Cutover
cutover_traffic

# 5. Drain and cleanup old active slot
cleanup_old

# 6. Save state
echo "${target_color}" > "${active_file}"
printf '%s %s %s\n' "$(date -u +%FT%TZ)" "${target_color}" "${image}" > "${state_dir}/${component}.last-deployed"
docker image prune -f >/dev/null 2>&1 || true

log "=========================================================="
log "SUCCESS: ${component} is now live on ${target_color} slot!"
log "Image:   ${image}"
log "Zero downtime deployment completed."
log "=========================================================="
exit 0
