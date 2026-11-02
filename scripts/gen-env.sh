#!/usr/bin/env bash
# Creates infra/.env (random data-tier secrets) and .env.local (app settings) if missing.
set -euo pipefail
cd "$(dirname "$0")/.."
rnd() { openssl rand -hex 16; }

if [ ! -f infra/.env ]; then
  cat > infra/.env <<EOF
BIND_IP=127.0.0.1
MYSQL_ROOT_PASSWORD=$(rnd)
MYSQL_DATABASE=student_db
MYSQL_USER=student
MYSQL_PASSWORD=$(rnd)
AUDIT_DB_PASSWORD=$(rnd)
REDIS_PASSWORD=$(rnd)
RABBITMQ_USER=edupulse
RABBITMQ_PASSWORD=$(rnd)
EOF
  chmod 600 infra/.env
  echo "created infra/.env"
fi

if [ ! -f .env.local ]; then
  cat > .env.local <<EOF
# Application logins. Local defaults only: change them for any shared environment.
ADMIN_USER=admin
ADMIN_PASSWORD=administrator
STUDENT_USER=student
STUDENT_PASSWORD=student123
COOKIE_SECURE=false
WEB_PORT=80
EOF
  chmod 600 .env.local
  echo "created .env.local"
fi
