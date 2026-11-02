# Every credential is generated here and lives only in Secrets Manager (and Terraform state,
# which is encrypted and access-controlled). Alphanumeric only: they end up inside URLs.
locals {
  generated = toset([
    "mysql_root", "mysql_app", "mysql_audit", "redis", "rabbitmq", "admin", "student",
  ])
}

resource "random_password" "this" {
  for_each = local.generated
  length   = 32
  special  = false
}

locals {
  rabbitmq_user = "edupulse"
  pw            = { for k, v in random_password.this : k => v.result }
  rabbitmq_url  = "amqp://${local.rabbitmq_user}:${local.pw["rabbitmq"]}@${local.infra_host}:5672"

  # One secret per consumer so each ECS execution role can read only what its service needs.
  secret_values = {
    infra = {
      MYSQL_ROOT_PASSWORD = local.pw["mysql_root"]
      MYSQL_PASSWORD      = local.pw["mysql_app"]
      AUDIT_DB_PASSWORD   = local.pw["mysql_audit"]
      REDIS_PASSWORD      = local.pw["redis"]
      RABBITMQ_PASSWORD   = local.pw["rabbitmq"]
    }
    auth = {
      REDIS_PASSWORD   = local.pw["redis"]
      RABBITMQ_URL     = local.rabbitmq_url
      ADMIN_PASSWORD   = local.pw["admin"]
      STUDENT_PASSWORD = local.pw["student"]
    }
    backend = {
      DB_PASSWORD  = local.pw["mysql_app"]
      RABBITMQ_URL = local.rabbitmq_url
    }
    audit = {
      DB_PASSWORD  = local.pw["mysql_audit"]
      RABBITMQ_URL = local.rabbitmq_url
    }
  }
}

resource "aws_secretsmanager_secret" "this" {
  tags = {
    Name               = "${var.project}/${var.environment}/${each.key}"
    Component          = each.key
    Tier               = each.key == "infra" ? "data" : "app"
    DataClassification = "secret"
  }
  for_each                = toset(["infra", "auth", "backend", "audit"])
  name                    = "${var.project}/${var.environment}/${each.key}"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each      = aws_secretsmanager_secret.this
  secret_id     = each.value.id
  secret_string = jsonencode(local.secret_values[each.key])
}
