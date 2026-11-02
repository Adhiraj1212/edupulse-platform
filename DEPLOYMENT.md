# EDUPULSE deployment

```
                    Internet
                       |  443/80
                    [ ALB ]
                       |  8080
        +--------------+----------------------------- ECS (private subnets) --+
        |  frontend (nginx)  --auth_request-->  auth-service  :4000           |
        |        |  \                               |   \                     |
        |        |   +--> audit-service :6000       |    +--publish events-+  |
        |        +------> backend :5000             |                      |  |
        +--------------------|-----------------------|----------------------|--+
                             | 3306                  | 6379                 | 5672
        +--------------------v-----------------------v----------------------v--+
        |  EC2 (private subnet) - infra/docker-compose.yaml                     |
        |  MySQL (student_db, audit_db)    Redis (sessions)    RabbitMQ         |
        +-----------------------------------------------------------------------+
```

| Directory | Runs on | What it is |
|---|---|---|
| `frontend/` | ECS | nginx: static site, reverse proxy, session check via auth-service |
| `backend/` | ECS | student REST API (MySQL) |
| `auth-service/` | ECS | logins, sessions in Redis, brute-force lockout |
| `audit-service/` | ECS | consumes RabbitMQ events into `audit_db`, `GET /api/audit` (teachers) |
| `infra/` | one EC2 | MySQL + Redis + RabbitMQ, single compose file |

## Run everything locally

```bash
bash scripts/local-up.sh        # creates infra/.env + .env.local with random secrets, builds, starts
bash scripts/smoke-test.sh      # 50 checks: routing, auth, roles, events, lockout, isolation
# open http://localhost
```

## Data tier on EC2 (`infra/`)

```bash
cd infra && cp .env.example .env     # replace every CHANGE_ME (openssl rand -hex 24)
# set BIND_IP to the instance's PRIVATE IPv4
docker compose up -d
```
Measured footprint is about 300 MB RAM; limits are 512 MB (MySQL), 160 MB (Redis) and 512 MB
(RabbitMQ), so a `t3.small` (2 GB) is comfortable. Put the Docker data volumes on an encrypted EBS volume.

## Connectivity (security groups)

| From | To | Port | Purpose |
|---|---|---|---|
| Internet | ALB | 443 | public entry; terminate TLS here |
| ALB SG | frontend tasks | 8080 | health check path `/healthz` |
| frontend SG | auth / backend / audit SG | 4000 / 5000 / 6000 | proxy and session check |
| auth SG | EC2 SG | 6379, 5672 | Redis, RabbitMQ |
| backend SG | EC2 SG | 3306, 5672 | MySQL, RabbitMQ |
| audit SG | EC2 SG | 3306, 5672 | MySQL, RabbitMQ |

Nothing else inbound on the EC2 SG (no SSH from the internet; use SSM Session Manager).
Only the frontend gets a load balancer. The three internal services must not.

## ECS task environment

Inject secrets from Secrets Manager or SSM Parameter Store (`secrets:` in the task definition), not as plain env.

| Service | Variables |
|---|---|
| frontend | `AUTH_UPSTREAM`, `BACKEND_UPSTREAM`, `AUDIT_UPSTREAM` (`host:port`, via Service Connect / Cloud Map), `DNS_RESOLVER=169.254.169.253`, `TRUSTED_PROXY_CIDR` = your VPC CIDR (so the real client IP is taken from the ALB's `X-Forwarded-For`) |
| auth-service | `REDIS_URL=redis://<ec2-ip>:6379`, `REDIS_PASSWORD`, `RABBITMQ_URL=amqp://user:pass@<ec2-ip>:5672`, `ADMIN_USER`, `ADMIN_PASSWORD`, `STUDENT_USER`, `STUDENT_PASSWORD`, `COOKIE_SECURE=true` |
| backend | `DB_HOST=<ec2-ip>`, `DB_USER`, `DB_PASSWORD`, `DB_DATABASE`, `DB_TABLE=students`, `RABBITMQ_URL` |
| audit-service | `DB_HOST=<ec2-ip>`, `DB_USER=audit`, `DB_PASSWORD`, `DB_DATABASE=audit_db`, `RABBITMQ_URL` |

`<ec2-ip>` is the instance's private IP, or better a private Route 53 name that points to it.
Task `healthCheck` command: `wget -qO- http://127.0.0.1:<port>/health` (4000, 5000, 6000), and `/healthz` on 8080 for the frontend.
Passwords go into URLs, so use hex or alphanumeric values.

## Production on AWS

Terraform, the pipelines and the full runbook live in [terraform/README.md](terraform/README.md):
VPC, ALB + WAF, ECS Fargate for the four services, the EC2 data host running `infra/`, secrets in
Secrets Manager, and GitHub Actions pipelines (build, scan, sign, approve, deploy) for every service.
The connectivity table above is generated from the same rules as the Terraform security groups.

For production, `infra/` is delivered by the `infra` workflow instead of by hand, and the ECS task
environment is set by Terraform. The per-service variable table above describes what that wiring provides.

## Known gaps

See the status and gaps sections of [terraform/README.md](terraform/README.md). The application-level ones:

- One shared login per role with the password in a secret. There are no per-user accounts.
- The backend uses one MySQL connection with no reconnect, so a DB restart needs a backend restart. A pool would fix it.
