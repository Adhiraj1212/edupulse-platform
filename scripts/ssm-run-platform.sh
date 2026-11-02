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

# Bundle deploy/docker-compose.yml, infra/db/init.sh, and infra/rabbitmq/rabbitmq.conf into a tarball
tar_b64="$(tar -C "${root_dir}" -czf - deploy/docker-compose.yml infra/db/init.sh infra/rabbitmq/rabbitmq.conf | base64 -w0 2>/dev/null || tar -C "${root_dir}" -czf - deploy/docker-compose.yml infra/db/init.sh infra/rabbitmq/rabbitmq.conf | base64 | tr -d '\r\n')"

remote_script=$(cat <<'EOF'
set -euo pipefail
workdir="/opt/edupulse"
mkdir -p "${workdir}/db" "${workdir}/rabbitmq" /var/lib/gha-deploy /tmp/edupulse-pkg

echo "$BUNDLE_B64" | base64 -d | tar -xzf - -C /tmp/edupulse-pkg
cp /tmp/edupulse-pkg/deploy/docker-compose.yml "${workdir}/docker-compose.yml"
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
echo "Starting data tier (db, redis, rabbitmq)..."
docker compose up -d db redis rabbitmq

echo "Checking health of data tier..."
for i in $(seq 1 30); do
  db_health=$(docker inspect --format='{{.State.Health.Status}}' edupulse-db-1 2>/dev/null || echo "starting")
  redis_health=$(docker inspect --format='{{.State.Health.Status}}' edupulse-redis-1 2>/dev/null || echo "starting")
  rmq_health=$(docker inspect --format='{{.State.Health.Status}}' edupulse-rabbitmq-1 2>/dev/null || echo "starting")
  
  if [ "$db_health" = "healthy" ] && [ "$redis_health" = "healthy" ] && [ "$rmq_health" = "healthy" ]; then
    echo "Data tier is healthy!"
    docker compose ps
    exit 0
  fi
  echo "Waiting for data tier health (attempt $i/30)... db: $db_health, redis: $redis_health, rabbitmq: $rmq_health"
  sleep 4
done

echo "Timed out waiting for data tier health" >&2
docker compose ps >&2
exit 1
EOF
)

b64_script="$(echo "${remote_script}" | base64 -w0 2>/dev/null || echo "${remote_script}" | base64 | tr -d '\r\n')"

params="$(jq -cn --arg b "$tar_b64" --arg s "$b64_script" \
  '{commands: [
    "set -euo pipefail",
    ("export BUNDLE_B64=\"" + $b + "\""),
    "echo \"" + $s + "\" | base64 -d > /tmp/deploy-platform.sh",
    "bash /tmp/deploy-platform.sh"
  ],
  executionTimeout: ["600"]}')"

cid="$(aws ssm send-command \
  --instance-ids "${instance}" \
  --document-name AWS-RunShellScript \
  --comment "github-actions deploy edupulse-platform" \
  --timeout-seconds 120 \
  --parameters "${params}" \
  --query Command.CommandId --output text)"

echo "SSM command id: ${cid} (instance ${instance})"

deadline=$(( $(date +%s) + 600 ))
status=Pending
while :; do
  status="$(aws ssm get-command-invocation --command-id "${cid}" --instance-id "${instance}" \
            --query Status --output text 2>/dev/null || echo Pending)"
  case "${status}" in
    Success|Failed|Cancelled|TimedOut|Cancelling) break ;;
  esac
  if [ "$(date +%s)" -ge "${deadline}" ]; then echo "timed out waiting for SSM" >&2; exit 1; fi
  sleep 4
done

echo "===== output (status: ${status}) ===== "
aws ssm get-command-invocation --command-id "${cid}" --instance-id "${instance}" \
  --query StandardOutputContent --output text
if [ "${status}" != "Success" ]; then
  echo "===== stderr ===== " >&2
  aws ssm get-command-invocation --command-id "${cid}" --instance-id "${instance}" \
    --query StandardErrorContent --output text >&2
  exit 1
fi

