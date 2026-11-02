# EduPulse Platform (`edupulse-platform`)

Infrastructure as Code (Terraform), Data-Tier Host orchestration, and End-to-End DevSecOps platform automation for the EduPulse microservices architecture.

## Architecture

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
        |  EC2 Data Host (private subnet) - infra/docker-compose.yaml          |
        |  MySQL 8.4 (student_db, audit_db)   Redis 7 (sessions)   RabbitMQ 4  |
        +----------------------------------------------------------------------+
```

## Directory Structure

* `terraform/`:
  - `bootstrap/`: One-time administrative setup: S3 remote state bucket, GitHub Actions OIDC provider, and CI IAM roles.
  - `envs/prod/`: Production infrastructure stack: VPC (3-tier, multi-AZ), ALB + WAF, ECS Fargate cluster & services, EC2 Data Host, Secrets Manager, Route 53 / Cloudflare DNS, CloudWatch alarms.
  - `modules/`:
    - `vpc/`: Multi-tier VPC with NAT gateways, flow logs, VPC endpoints.
    - `data-host/`: EC2 instance with encrypted EBS data volume, IMDSv2, SSM Session Manager (no SSH), and systemd boot scripts.
    - `ecs-service/`: Reusable Fargate service module with autoscaling, CloudWatch logs, and circuit breaker rollbacks.
* `infra/`: Docker Compose stack for MySQL, Redis, and RabbitMQ running on the private EC2 host.
* `scripts/`: Local orchestration and smoke testing scripts.

## DevSecOps Pipeline

1. **Secret Scanning:** `gitleaks` checks all commits for accidentally committed secrets.
2. **IaC Formatting & Validation:** `terraform fmt -check` and `terraform validate`.
3. **IaC Linting & Tag Standards:** `tflint` enforces standard resource tags (`Project`, `Environment`, `ManagedBy`, `Stack`, `Owner`, `CostCenter`).
4. **IaC Security & Compliance Scanning:** Bridgecrew `checkov` scans for compliance, security group exposures, and encryption standards.
5. **OIDC Plan Execution:** Generates an execution plan with read-only permissions and posts it to the GitHub Step Summary.
6. **Environment Approval Gate:** Applying changes to production requires human approval in GitHub Actions (`prod-infra` environment).
7. **SSM Zero-SSH Host Deploy:** Updates the data host using AWS Systems Manager Run Command (`aws ssm send-command`).

## Multi-Repo Service Ecosystem

This platform provisions infrastructure for 4 independent microservice repositories:
* [`edupulse-frontend`](../edupulse-frontend): Web UI & Nginx Reverse Proxy
* [`edupulse-backend`](../edupulse-backend): Student Management REST API
* [`edupulse-auth-service`](../edupulse-auth-service): Session Management & Auth
* [`edupulse-audit-service`](../edupulse-audit-service): Audit Logging Consumer

## Local End-to-End Orchestration & Smoke Testing

To run and verify the entire system locally before deploying:

```bash
# 1. Generate local secrets and start all 4 services + data stores
bash scripts/local-up.sh

# 2. Run the 50-check DevSecOps automated smoke test
bash scripts/smoke-test.sh

# 3. Stop and clean up
bash scripts/local-down.sh
```
