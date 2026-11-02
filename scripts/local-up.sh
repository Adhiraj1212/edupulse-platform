#!/usr/bin/env bash
# Build and start the whole system locally. Extra args go to `docker compose up`.
# Other commands: scripts/local-up.sh is the only wrapper you need to remember the flags of:
#   docker compose --env-file infra/.env --env-file .env.local -f docker-compose.local.yaml <cmd>
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/gen-env.sh
docker compose --env-file infra/.env --env-file .env.local -f docker-compose.local.yaml up -d --build --remove-orphans "$@"
