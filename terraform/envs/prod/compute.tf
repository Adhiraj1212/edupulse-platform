# ---------------- data host (MySQL + Redis + RabbitMQ on one EC2) ----------------
module "data_host" {
  source = "../../modules/data-host"

  name               = local.name
  subnet_id          = module.vpc.data_subnet_ids[0]
  availability_zone  = module.vpc.data_subnet_azs[0]
  private_ip         = cidrhost(module.vpc.data_subnet_cidrs[0], 10)
  security_group_ids = [aws_security_group.this["data"].id]
  instance_type      = var.infra_instance_type
  data_volume_gb     = var.infra_data_volume_gb
  kms_key_arn        = aws_kms_key.main.arn
  artifacts_bucket   = aws_s3_bucket.this["artifacts"].id
  secret_arn         = aws_secretsmanager_secret.this["infra"].arn
}

# ---------------- service discovery: <service>.edupulse.internal ----------------
resource "aws_service_discovery_private_dns_namespace" "this" {
  tags = { Name = local.namespace, Component = "service-discovery", Tier = "platform" }
  name = local.namespace
  vpc  = module.vpc.vpc_id
}

# Stable name for the data host so no service ever hard-codes an IP
resource "aws_route53_record" "infra" {
  zone_id = aws_service_discovery_private_dns_namespace.this.hosted_zone
  name    = local.infra_host
  type    = "A"
  ttl     = 30
  records = [module.data_host.private_ip]
}

# ---------------- ECS ----------------
resource "aws_ecs_cluster" "this" {
  tags = { Name = local.name, Component = "ecs-cluster", Tier = "platform" }
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

locals {
  repo_url = { for k, r in aws_ecr_repository.this : k => r.repository_url }

  secret_ref = {
    for k in ["auth", "backend", "audit"] :
    k => { for key in keys(local.secret_values[k]) : key => "${aws_secretsmanager_secret.this[k].arn}:${key}::" }
  }
}

module "frontend" {
  source = "../../modules/ecs-service"

  tier = "web"

  name                     = "frontend"
  cluster_name             = aws_ecs_cluster.this.name
  cluster_arn              = aws_ecs_cluster.this.arn
  subnet_ids               = module.vpc.private_subnet_ids
  security_group_ids       = [aws_security_group.this["frontend"].id]
  image_repository         = local.repo_url["frontend"]
  container_port           = 8080
  kms_key_arn              = aws_kms_key.main.arn
  readonly_root_filesystem = false # nginx renders its config into /etc/nginx/conf.d at start
  health_check_command     = "wget -qO- http://127.0.0.1:8080/healthz || exit 1"
  min_capacity             = 2
  max_capacity             = 6
  target_group_arn         = aws_lb_target_group.frontend.arn

  environment = {
    AUTH_UPSTREAM      = "auth-service.${local.namespace}:4000"
    BACKEND_UPSTREAM   = "backend.${local.namespace}:5000"
    AUDIT_UPSTREAM     = "audit-service.${local.namespace}:6000"
    DNS_RESOLVER       = "169.254.169.253" # Amazon-provided DNS, reachable from any VPC
    TRUSTED_PROXY_CIDR = var.vpc_cidr      # take the client IP from the ALB's X-Forwarded-For
  }

  depends_on = [aws_lb_listener_rule.app]
}

module "auth_service" {
  source = "../../modules/ecs-service"

  tier = "app"

  name                           = "auth-service"
  cluster_name                   = aws_ecs_cluster.this.name
  cluster_arn                    = aws_ecs_cluster.this.arn
  subnet_ids                     = module.vpc.private_subnet_ids
  security_group_ids             = [aws_security_group.this["auth"].id]
  image_repository               = local.repo_url["auth-service"]
  container_port                 = 4000
  kms_key_arn                    = aws_kms_key.main.arn
  health_check_command           = "wget -qO- http://127.0.0.1:4000/health || exit 1"
  min_capacity                   = 2
  max_capacity                   = 4
  service_discovery_namespace_id = aws_service_discovery_private_dns_namespace.this.id
  secret_arns                    = [aws_secretsmanager_secret.this["auth"].arn]

  environment = {
    REDIS_URL     = "redis://${local.infra_host}:6379"
    ADMIN_USER    = "admin"
    STUDENT_USER  = "student"
    COOKIE_SECURE = "true"
  }
  secrets = local.secret_ref["auth"]
}

module "backend" {
  source = "../../modules/ecs-service"

  tier = "app"

  name                           = "backend"
  cluster_name                   = aws_ecs_cluster.this.name
  cluster_arn                    = aws_ecs_cluster.this.arn
  subnet_ids                     = module.vpc.private_subnet_ids
  security_group_ids             = [aws_security_group.this["backend"].id]
  image_repository               = local.repo_url["backend"]
  container_port                 = 5000
  kms_key_arn                    = aws_kms_key.main.arn
  health_check_command           = "wget -qO- http://127.0.0.1:5000/health || exit 1"
  min_capacity                   = 2
  max_capacity                   = 6
  service_discovery_namespace_id = aws_service_discovery_private_dns_namespace.this.id
  secret_arns                    = [aws_secretsmanager_secret.this["backend"].arn]

  environment = {
    DB_HOST     = local.infra_host
    DB_USER     = "student"
    DB_DATABASE = "student_db"
    DB_TABLE    = "students"
  }
  secrets = local.secret_ref["backend"]
}

module "audit_service" {
  source = "../../modules/ecs-service"

  tier = "app"

  name                           = "audit-service"
  cluster_name                   = aws_ecs_cluster.this.name
  cluster_arn                    = aws_ecs_cluster.this.arn
  subnet_ids                     = module.vpc.private_subnet_ids
  security_group_ids             = [aws_security_group.this["audit"].id]
  image_repository               = local.repo_url["audit-service"]
  container_port                 = 6000
  kms_key_arn                    = aws_kms_key.main.arn
  health_check_command           = "wget -qO- http://127.0.0.1:6000/health || exit 1"
  min_capacity                   = 1
  max_capacity                   = 2
  service_discovery_namespace_id = aws_service_discovery_private_dns_namespace.this.id
  secret_arns                    = [aws_secretsmanager_secret.this["audit"].arn]

  environment = {
    DB_HOST     = local.infra_host
    DB_USER     = "audit"
    DB_DATABASE = "audit_db"
  }
  secrets = local.secret_ref["audit"]
}

locals {
  # name in AWS => module outputs, used by IAM, alarms and outputs
  ecs_services = {
    "frontend"      = module.frontend
    "auth-service"  = module.auth_service
    "backend"       = module.backend
    "audit-service" = module.audit_service
  }
}
