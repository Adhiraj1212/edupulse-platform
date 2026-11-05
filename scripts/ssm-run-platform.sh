#!/usr/bin/env bash
# Runner side (GitHub Actions): ship infra/platform compose & configs to EC2 via SSM Run Command
set -euo pipefail

instance="${1:-${INSTANCE_ID:-}}"
if [ -z "$instance" ]; then
  echo "Error: Target EC2 instance ID is required. Pass as argument or set INSTANCE_ID env var." >&2
  exit 1
fi
region="${AWS_REGION:-eu-north-1}"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Bundle deploy/docker-compose.yml, gateway, frontend, upstreams, db/init.sh, and rabbitmq.conf into a tarball
tar_b64="$(tar -C "${root_dir}" -czf - deploy/docker-compose.yml deploy/gateway/ deploy/frontend/ deploy/upstreams/ infra/db/init.sh infra/rabbitmq/rabbitmq.conf | base64 -w0 2>/dev/null || tar -C "${root_dir}" -czf - deploy/docker-compose.yml deploy/gateway/ deploy/frontend/ deploy/upstreams/ infra/db/init.sh infra/rabbitmq/rabbitmq.conf | base64 | tr -d '\r\n')"

remote_script=$(cat <<'EOF'
set -euo pipefail
workdir="/opt/edupulse"
mkdir -p "${workdir}/db" "${workdir}/rabbitmq" "${workdir}/gateway" "${workdir}/frontend" "${workdir}/upstreams" /var/lib/gha-deploy /tmp/edupulse-pkg

echo "$BUNDLE_B64" | base64 -d | tar -xzf - -C /tmp/edupulse-pkg
cp /tmp/edupulse-pkg/deploy/docker-compose.yml "${workdir}/docker-compose.yml"
cp -r /tmp/edupulse-pkg/deploy/gateway/* "${workdir}/gateway/"
cp -r /tmp/edupulse-pkg/deploy/frontend/* "${workdir}/frontend/"

# Copy default upstreams only if not already present, preserving active color
for conf in /tmp/edupulse-pkg/deploy/upstreams/*.conf; do
  fname="$(basename "$conf")"
  if [ ! -f "${workdir}/upstreams/${fname}" ]; then
    cp "$conf" "${workdir}/upstreams/${fname}"
    echo "Initialized default upstream ${fname}"
  fi
done

cp /tmp/edupulse-pkg/infra/db/init.sh "${workdir}/db/init.sh"
chmod +x "${workdir}/db/init.sh"
cp /tmp/edupulse-pkg/infra/rabbitmq/rabbitmq.conf "${workdir}/rabbitmq/rabbitmq.conf"
rm -rf /tmp/edupulse-pkg

if [ ! -f "${workdir}/.env" ]; then
  cat <<ENVEOF > "${workdir}/.env"
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)
MYSQL_DATABASE=student_db
MYSQL_USER=student
MYSQL_PASSWORD=$(openssl rand -hex 16)
AUDIT_DB_PASSWORD=$(openssl rand -hex 16)
REDIS_PASSWORD=$(openssl rand -hex 16)
RABBITMQ_USER=edupulse
RABBITMQ_PASSWORD=$(openssl rand -hex 16)
ADMIN_USER=admin
ADMIN_PASSWORD=administrator
STUDENT_USER=student
STUDENT_PASSWORD=student123
COOKIE_SECURE=false
WEB_PORT=80
ENVEOF
  chmod 600 "${workdir}/.env"
  echo "Generated ${workdir}/.env with random secrets"
fi

cd "${workdir}"

# Initialize default active color state if not present
for comp in frontend auth-service backend audit-service; do
  if [ ! -f "/var/lib/gha-deploy/${comp}.color" ]; then
    echo "blue" > "/var/lib/gha-deploy/${comp}.color"
  fi
done

# If legacy single containers exist, clean them up to transition to Blue/Green
if docker ps -a --format '{{.Names}}' | grep -q '^edupulse-frontend-1$'; then
  echo "Transitioning legacy frontend to gateway + frontend-blue..."
  docker stop edupulse-frontend-1 2>/dev/null || true
  docker rm -f edupulse-frontend-1 2>/dev/null || true
fi
for comp in auth-service backend audit-service; do
  if docker ps -a --format '{{.Names}}' | grep -q "^edupulse-${comp}-1$"; then
    echo "Transitioning legacy ${comp} to ${comp}-blue..."
    docker stop "edupulse-${comp}-1" 2>/dev/null || true
    docker rm -f "edupulse-${comp}-1" 2>/dev/null || true
  fi
done

echo "Starting data tier, gateway, and initial blue services..."
docker compose up -d --force-recreate db redis rabbitmq gateway auth-service-blue backend-blue audit-service-blue frontend-blue

echo "Checking health of data tier and gateway..."
for i in $(seq 1 30); do
  db_health=$(docker inspect --format='{{.State.Health.Status}}' edupulse-db-1 2>/dev/null || echo "starting")
  redis_health=$(docker inspect --format='{{.State.Health.Status}}' edupulse-redis-1 2>/dev/null || echo "starting")
  rmq_health=$(docker inspect --format='{{.State.Health.Status}}' edupulse-rabbitmq-1 2>/dev/null || echo "starting")
  
  if [ "$db_health" = "healthy" ] && [ "$redis_health" = "healthy" ] && [ "$rmq_health" = "healthy" ]; then
    echo "Data tier is healthy!"
    break
  fi
  sleep 3
done

docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
EOF
)

remote_script_b64="$(echo "${remote_script}" | base64 -w0 2>/dev/null || echo "${remote_script}" | base64 | tr -d '\r\n')"

params="$(jq -cn --arg b "${tar_b64}" --arg s "${remote_script_b64}" \
  '{commands: [
    "set -euo pipefail",
    "export BUNDLE_B64=\"" + $b + "\"",
    "echo \"" + $s + "\" | base64 -d | bash"
  ], executionTimeout: ["600"]}')"

echo "Triggering SSM Run Command on ${instance} in ${region}..."
cid="$(aws ssm send-command \
  --instance-ids "${instance}" \
  --document-name "AWS-RunShellScript" \
  --region "${region}" \
  --parameters "${params}" \
  --timeout-seconds 120 \
  --comment "Deploy EduPulse Platform & Data Tier" \
  --query "Command.CommandId" \
  --output text)"

echo "SSM Command ID: ${cid}. Waiting for completion..."

deadline=$(( $(date +%s) + 600 ))
status=Pending
while :; do
  status="$(aws ssm get-command-invocation \
    --command-id "${cid}" \
    --instance-id "${instance}" \
    --region "${region}" \
    --query "Status" \
    --output text 2>/dev/null || echo "Pending")"
  case "${status}" in
    Success|Failed|Cancelled|TimedOut|Cancelling) break ;;
  esac
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "Timed out waiting for platform deployment." >&2
    exit 1
  fi
  sleep 5
done

echo "===== SSM Command Output (Status: ${status}) ====="
aws ssm get-command-invocation \
  --command-id "${cid}" \
  --instance-id "${instance}" \
  --region "${region}" \
  --query "StandardOutputContent" \
  --output text

if [ "${status}" != "Success" ]; then
  echo "===== SSM Standard Error =====" >&2
  aws ssm get-command-invocation \
    --command-id "${cid}" \
    --instance-id "${instance}" \
    --region "${region}" \
    --query "StandardErrorContent" \
    --output text >&2
  exit 1
fi

echo "Platform deployment completed successfully!"
