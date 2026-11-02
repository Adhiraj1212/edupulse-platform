terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_arn" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "image_repository" {
  type = string
}

# CI registers new task definition revisions with real image tags; Terraform only seeds the first one.
variable "image_tag" {
  type    = string
  default = "bootstrap"
}

variable "container_port" {
  type = number
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "environment" {
  type    = map(string)
  default = {}
}

variable "secrets" {
  description = "Env var name => Secrets Manager valueFrom (arn:key::)."
  type        = map(string)
  default     = {}
}

variable "secret_arns" {
  description = "Secrets the execution role may read."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "CMK that encrypts the secrets and the log group."
  type        = string
}

variable "health_check_command" {
  type = string
}

variable "readonly_root_filesystem" {
  type    = bool
  default = true
}

variable "min_capacity" {
  type    = number
  default = 2
}

variable "max_capacity" {
  type    = number
  default = 4
}

variable "cpu_target_percent" {
  type    = number
  default = 60
}

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "target_group_arn" {
  type    = string
  default = null
}

variable "service_discovery_namespace_id" {
  description = "Cloud Map private DNS namespace; the service becomes <name>.<namespace>."
  type        = string
  default     = null
}

variable "tier" {
  description = "Tier tag: web or app."
  type        = string
  default     = "app"
}

variable "tags" {
  description = "Extra tags merged into the service's tags."
  type        = map(string)
  default     = {}
}

data "aws_region" "current" {}

locals {
  tags = merge(var.tags, {
    Name      = "${var.cluster_name}-${var.name}"
    Service   = var.name
    Component = var.name
    Tier      = var.tier
  })
}

resource "aws_cloudwatch_log_group" "this" {
  tags              = local.tags
  name              = "/ecs/${var.cluster_name}/${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: pulls the image, writes logs, reads ONLY this service's secrets.
resource "aws_iam_role" "execution" {
  tags               = local.tags
  name               = "${var.cluster_name}-${var.name}-exec"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "secrets" {
  count = length(var.secret_arns) > 0 ? 1 : 0
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "secrets" {
  count  = length(var.secret_arns) > 0 ? 1 : 0
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.secrets[0].json
}

# Task role: what the application code itself may call in AWS. These services need nothing.
resource "aws_iam_role" "task" {
  tags               = local.tags
  name               = "${var.cluster_name}-${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

locals {
  container = {
    name         = var.name
    image        = "${var.image_repository}:${var.image_tag}"
    essential    = true
    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
    environment  = [for k, v in var.environment : { name = k, value = v }]
    secrets      = [for k, v in var.secrets : { name = k, valueFrom = v }]

    readonlyRootFilesystem = var.readonly_root_filesystem
    linuxParameters = {
      initProcessEnabled = true
      capabilities       = { drop = ["ALL"] }
    }
    healthCheck = {
      command     = ["CMD-SHELL", var.health_check_command]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = var.name
      }
    }
  }
}

resource "aws_ecs_task_definition" "this" {
  tags                     = local.tags
  family                   = "${var.cluster_name}-${var.name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = jsonencode([local.container])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

resource "aws_service_discovery_service" "this" {
  count = var.service_discovery_namespace_id == null ? 0 : 1
  name  = var.name
  tags  = local.tags

  dns_config {
    namespace_id   = var.service_discovery_namespace_id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_ecs_service" "this" {
  tags                               = local.tags
  name                               = var.name
  cluster                            = var.cluster_arn
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = 0 # CI starts it on first deploy; autoscaling owns it afterwards
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = var.target_group_arn == null ? null : 60
  enable_execute_command             = false
  propagate_tags                     = "SERVICE"
  enable_ecs_managed_tags            = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [1]
    content {
      target_group_arn = var.target_group_arn
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  dynamic "service_registries" {
    for_each = aws_service_discovery_service.this
    content {
      registry_arn = service_registries.value.arn
    }
  }

  lifecycle {
    # The pipeline owns the running task definition and autoscaling owns the count.
    ignore_changes = [task_definition, desired_count]
  }
}

resource "aws_appautoscaling_target" "this" {
  tags               = local.tags
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  resource_id        = aws_appautoscaling_target.this.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_percent
    scale_in_cooldown  = 120
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "task_family" {
  value = aws_ecs_task_definition.this.family
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "service_arn" {
  value = aws_ecs_service.this.id
}
