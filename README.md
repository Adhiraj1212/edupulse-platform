# EduPulse Platform (`edupulse-platform`)

> **The GitOps Infrastructure, Shared Data-Tier, and Orchestration Hub for EduPulse.**  
> Manages the foundational stack (MySQL 8.4, Redis 7, RabbitMQ 4), network topology, and remote deployment automation for the EduPulse microservices architecture.

---

## 1. System Architecture

EduPulse runs a containerized microservices stack on AWS EC2, orchestrated using Docker Compose and deployed completely **without SSH keys** via **AWS Systems Manager (SSM)** and **GitHub Actions OIDC**:

```
                         Public Internet
                                |
                                | HTTP (Port 80)
                                v
+-------------------------------------------------------------------------+
| AWS EC2 INSTANCE (Security Group: Port 80 Open, Port 22 CLOSED)          |
|                                                                         |
| Base Configuration: /opt/edupulse/docker-compose.yml                    |
| Service Overrides:  /var/lib/gha-deploy/<service>.override.yml          |
|                                                                         |
|  Docker Bridge Network: edupulse-net                                    |
|  ├── edupulse-frontend-1     (Nginx Reverse Proxy & UI) :80             |
|  ├── edupulse-backend-1      (Node.js API)              :5000           |
|  ├── edupulse-auth-service-1 (Authentication)           :4000           |
|  ├── edupulse-audit-service-1(Audit Consumer)           :6000           |
|  ├── edupulse-db-1           (MySQL 8.4)                :3306           |
|  ├── edupulse-redis-1        (Redis 7)                  :6379           |
|  └── edupulse-rabbitmq-1     (RabbitMQ 4)               :5672           |
+-------------------------------------------------------------------------+
                                ^
                                | AWS SSM Run Command (HTTPS 443 outbound)
                                | Authenticated via AWS IAM OIDC
+-------------------------------------------------------------------------+
| GitHub Actions Workflows (Across 5 Repositories)                        |
|  1. edupulse-platform        (Deploys shared data-tier & base compose)  |
|  2. edupulse-auth-service    (Independent DevSecOps CI/CD)              |
|  3. edupulse-backend         (Independent DevSecOps CI/CD)              |
|  4. edupulse-audit-service   (Independent DevSecOps CI/CD)              |
|  5. edupulse-frontend        (Independent DevSecOps CI/CD)              |
+-------------------------------------------------------------------------+
```

---

## 2. Multi-Repo Microservice Ecosystem

EduPulse is modularized across 5 independent GitHub repositories:

| Repository | Purpose | Ports / Tech |
| :--- | :--- | :--- |
| **`edupulse-platform`** *(this repo)* | GitOps, Data tier, Compose Orchestration | MySQL (3306), Redis (6379), RabbitMQ (5672) |
| [**`edupulse-frontend`**](../edupulse-frontend) | Web Interface & Nginx Reverse Proxy | Port 80 (public) -> 8080 (container) |
| [**`edupulse-backend`**](../edupulse-backend) | Student Management REST API | Port 5000 (Node.js 22) |
| [**`edupulse-auth-service`**](../edupulse-auth-service) | Session Auth & Rate Limiting | Port 4000 (Node.js 22) |
| [**`edupulse-audit-service`**](../edupulse-audit-service) | Event Consumer & Audit Logging | Port 6000 (Node.js 22) |

---

## 3. How to Spin Up This Server (Quickstart for Learners)

To deploy this platform onto your own AWS account:

### Step 1: Launch an EC2 Instance (No SSH Port!)
1. Launch an Ubuntu 24.04 (or 22.04) `t3.medium` instance.
2. Configure the Security Group:
   - **Inbound:** Allow **HTTP (Port 80)** from `0.0.0.0/0`.
   - **Do NOT open Port 22.**
3. Create an IAM Role for EC2 with the managed policy:
   - `AmazonSSMManagedInstanceCore`
4. Attach this role to your EC2 instance as its Instance Profile.

### Step 2: Set Up AWS OIDC for GitHub Actions
1. In AWS IAM -> Identity Providers -> Add Provider:
   - Provider URL: `https://token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`
2. Create an IAM Role (e.g. `GitHubActions-devops-ec2ssm-role`) with a trust policy allowing your GitHub repositories to assume the role via WebIdentity:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "Federated": "arn:aws:iam::<YOUR_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
         },
         "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {
           "StringEquals": {
             "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
           },
           "StringLike": {
             "token.actions.githubusercontent.com:sub": [
               "repo:*edupulse-*:*"
             ]
           }
         }
       }
     ]
   }
   ```
3. Attach permissions to the role allowing SSM Run Command (`ssm:SendCommand`, `ssm:GetCommandInvocation`, `ssm:DescribeInstanceInformation`).

### Step 3: Store GHCR Pull Credentials in SSM Parameter Store
On the EC2 host, Docker pulls images from the GitHub Container Registry. Store your GitHub credentials in SSM Parameter Store:
```bash
aws ssm put-parameter --name "/devsecops-demo/prod/ghcr_pull_user" --value "<GITHUB_USERNAME>" --type "String"
aws ssm put-parameter --name "/devsecops-demo/prod/ghcr_pull_token" --value "<GITHUB_PAT_WITH_READ_PACKAGES>" --type "SecureString"
```

### Step 4: Configure GitHub Actions Variables
In your forked/created GitHub repositories, navigate to:
**Settings** -> **Secrets and variables** -> **Actions** -> **Variables** tab, and add:
- `AWS_ROLE_ARN`: `arn:aws:iam::<YOUR_ACCOUNT_ID>:role/GitHubActions-devops-ec2ssm-role`
- `INSTANCE_ID`: `i-<your-ec2-instance-id>`
- `AWS_REGION`: `eu-north-1` (or your preferred region)

### Step 5: Deploy the Platform
Push to `main` in `edupulse-platform` (or trigger `platform-infra-ci-cd` under the **Actions** tab). This will:
1. Validate compose configurations and init scripts.
2. Ship `docker-compose.yml`, database schemas, and RabbitMQ configs to `/opt/edupulse` on the EC2 host via SSM.
3. Automatically launch and healthcheck MySQL 8.4, Redis 7, and RabbitMQ 4!

Once the platform is running, push each of the 4 microservices to trigger their DevSecOps pipelines and rolling SSM deployments!

---

## 4. Deep-Dive Guides

For detailed, step-by-step instructions, troubleshooting scenarios, and security explanations, check out:
- [**EduPulse DevSecOps & GitOps Handbook**](docs/EDUPULSE_DEVOPS_HANDBOOK.md): Complete guide with architecture diagrams, real-world bug fixes, and deployment cheatsheet.
- [**Local Development & Testing**](docker-compose.local.yaml): Run the complete stack locally on your workstation.
