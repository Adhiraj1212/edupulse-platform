# ---------------- TLS certificate (wildcard, validated through Cloudflare DNS) ----------------
locals {
  app_hostnames = [for sub in var.app_subdomains : "${sub}.${var.root_domain}"]
}

resource "aws_acm_certificate" "this" {
  tags                      = { Name = "${local.name}-wildcard", Component = "tls", Tier = "edge" }
  domain_name               = "*.${var.root_domain}"
  subject_alternative_names = [var.root_domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  # the wildcard and the apex share one validation CNAME: group them so it is created once
  cert_validation = {
    for o in aws_acm_certificate.this.domain_validation_options : trimsuffix(o.resource_record_name, ".") => {
      type  = o.resource_record_type
      value = trimsuffix(o.resource_record_value, ".")
    }...
  }
}

resource "cloudflare_record" "cert_validation" {
  for_each        = local.cert_validation
  zone_id         = var.cloudflare_zone_id
  name            = each.key
  type            = each.value[0].type
  content         = each.value[0].value
  ttl             = 60
  proxied         = false # ACM must see the record unproxied
  allow_overwrite = true
  comment         = "ACM validation (terraform)"
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn = aws_acm_certificate.this.arn
  depends_on      = [cloudflare_record.cert_validation]
}

# ---------------- load balancer ----------------
resource "aws_lb" "this" {
  tags                       = { Name = local.name, Component = "alb", Tier = "edge" }
  name                       = local.name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = module.vpc.public_subnet_ids
  security_groups            = [aws_security_group.this["alb"].id]
  drop_invalid_header_fields = true
  enable_deletion_protection = true

  access_logs {
    bucket  = aws_s3_bucket.this["alb_logs"].id
    prefix  = "alb"
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.this]
}

resource "aws_lb_target_group" "frontend" {
  tags                 = { Name = "${local.name}-frontend", Component = "frontend", Tier = "web" }
  name                 = "${local.name}-frontend"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = module.vpc.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  # Anything that is not a known hostname (scanners hitting the raw ALB name, stray DNS) gets a 404.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "app" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }

  condition {
    host_header {
      values = local.app_hostnames
    }
  }
}

# DNS-only (grey cloud): browsers connect straight to the ALB, which holds the TLS certificate.
# Orange-cloud proxying needs extra work first (trusted Cloudflare ranges for the real client IP,
# ALB security group limited to Cloudflare), otherwise login lockouts would hit every user at once.
resource "cloudflare_record" "app" {
  for_each = toset(local.app_hostnames)
  zone_id  = var.cloudflare_zone_id
  name     = each.value
  type     = "CNAME"
  content  = aws_lb.this.dns_name
  ttl      = 300
  proxied  = false
  comment  = "EDUPULSE web app (terraform)"
}

# ---------------- web application firewall ----------------
locals {
  managed_rules = {
    common        = { name = "AWSManagedRulesCommonRuleSet", priority = 10 }
    known-bad     = { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20 }
    ip-reputation = { name = "AWSManagedRulesAmazonIpReputationList", priority = 30 }
  }
}

resource "aws_wafv2_web_acl" "this" {
  tags  = { Name = local.name, Component = "waf", Tier = "edge" }
  name  = local.name
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # Credential stuffing guard on top of the app's own lockout
  rule {
    name     = "login-rate-limit"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 100 # requests per 5 minutes per IP
        aggregate_key_type = "IP"
        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/login"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "login-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "global-rate-limit"
    priority = 2
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "global-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.managed_rules
    content {
      name     = rule.key
      priority = rule.value.priority
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudwatch_log_group" "waf" {
  tags              = { Name = "aws-waf-logs-${local.name}", Component = "waf", Tier = "edge" }
  name              = "aws-waf-logs-${local.name}" # WAF requires this prefix
  retention_in_days = 365
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # session cookies and auth headers must never land in logs
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}
