module "vpc" {
  source = "../../modules/vpc"

  name               = local.name
  cidr               = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  kms_key_arn        = aws_kms_key.main.arn

  depends_on = [aws_kms_key.main]
}

# ---------------- security groups ----------------
# One group per component. Traffic is allowed only along the explicit `flows` below;
# each flow creates the egress rule on the caller and the ingress rule on the callee.
resource "aws_security_group" "this" {
  tags = {
    Name      = "${local.name}-${each.key}"
    Component = each.key
    Tier      = { alb = "edge", frontend = "web", auth = "app", backend = "app", audit = "app", data = "data" }[each.key]
  }
  for_each    = toset(["alb", "frontend", "auth", "backend", "audit", "data"])
  name        = "${local.name}-${each.key}"
  description = "${local.name} ${each.key}"
  vpc_id      = module.vpc.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  flows = {
    alb-to-frontend     = { from = "alb", to = "frontend", port = 8080 }
    frontend-to-auth    = { from = "frontend", to = "auth", port = 4000 }
    frontend-to-backend = { from = "frontend", to = "backend", port = 5000 }
    frontend-to-audit   = { from = "frontend", to = "audit", port = 6000 }
    auth-to-redis       = { from = "auth", to = "data", port = 6379 }
    auth-to-rabbitmq    = { from = "auth", to = "data", port = 5672 }
    backend-to-mysql    = { from = "backend", to = "data", port = 3306 }
    backend-to-rabbitmq = { from = "backend", to = "data", port = 5672 }
    audit-to-mysql      = { from = "audit", to = "data", port = 3306 }
    audit-to-rabbitmq   = { from = "audit", to = "data", port = 5672 }
  }
}

resource "aws_vpc_security_group_egress_rule" "flow" {
  for_each                     = local.flows
  security_group_id            = aws_security_group.this[each.value.from].id
  referenced_security_group_id = aws_security_group.this[each.value.to].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.key
}

resource "aws_vpc_security_group_ingress_rule" "flow" {
  for_each                     = local.flows
  security_group_id            = aws_security_group.this[each.value.to].id
  referenced_security_group_id = aws_security_group.this[each.value.from].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.key
}

# The load balancer is the only thing the internet can reach.
resource "aws_vpc_security_group_ingress_rule" "alb_public" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.this["alb"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  description       = "public ${each.value}"
}

# Tasks and the data host need HTTPS out (ECR, Secrets Manager, CloudWatch, SSM, package repos) via NAT.
resource "aws_vpc_security_group_egress_rule" "https_out" {
  for_each          = toset(["frontend", "auth", "backend", "audit", "data"])
  security_group_id = aws_security_group.this[each.value].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "https out"
}
