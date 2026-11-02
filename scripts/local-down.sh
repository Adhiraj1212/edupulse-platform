#!/usr/bin/env bash
# Stop the whole local system. Data (MySQL, Redis, RabbitMQ volumes) is kept.
#   scripts/local-down.sh            stop and remove containers, keep data
#   scripts/local-down.sh --wipe     also delete all data volumes (fresh start)
set -euo pipefail
cd "$(dirname "$0")/.."

args=(--remove-orphans)
if [ "${1:-}" = "--wipe" ]; then
  args+=(--volumes)
  echo "Wiping data volumes too."
fi

docker compose --env-file infra/.env --env-file .env.local -f docker-compose.local.yaml down "${args[@]}"
