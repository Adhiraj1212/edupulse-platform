data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Applied to every taggable resource through the provider's default_tags
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Stack       = "envs/prod"
    Repository  = var.github_repository
    Owner       = var.owner
    CostCenter  = var.cost_center
  }

  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  namespace  = "${var.project}.internal"
  infra_host = "infra.${local.namespace}"
  ecr_repos  = toset(["frontend", "backend", "auth-service", "audit-service"])
}

# ---------------- one CMK for secrets, logs, volumes and images ----------------
data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "EnableIamPolicies"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid = "AllowCloudWatchLogs"
    actions = [
      "kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.name}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${data.aws_region.current.name}:${local.account_id}:log-group:*"]
    }
  }
}

data "aws_iam_policy_document" "kms_alarms" {
  source_policy_documents = [data.aws_iam_policy_document.kms.json]

  statement {
    sid       = "AllowCloudWatchAlarmsToUseEncryptedTopic"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "main" {
  tags                    = { Name = local.name, Component = "encryption", Tier = "platform" }
  description             = "${local.name} secrets, logs, volumes, images"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms_alarms.json
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}

# ---------------- buckets ----------------
locals {
  buckets = {
    artifacts = "${local.name}-artifacts-${local.account_id}"
    alb_logs  = "${local.name}-alb-logs-${local.account_id}"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets
  bucket   = each.value
  tags     = { Name = each.value, Component = each.key, Tier = "platform", DataClassification = "internal" }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = aws_s3_bucket.this
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    bucket_key_enabled = each.key == "artifacts"
    apply_server_side_encryption_by_default {
      # ALB log delivery does not support KMS, so only the logs bucket uses SSE-S3
      sse_algorithm     = each.key == "artifacts" ? "aws:kms" : "AES256"
      kms_master_key_id = each.key == "artifacts" ? aws_kms_key.main.arn : null
    }
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.this["artifacts"].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.this["alb_logs"].id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.this["artifacts"].id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

data "aws_elb_service_account" "main" {}

data "aws_iam_policy_document" "bucket" {
  for_each = aws_s3_bucket.this

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "alb_logs" ? [1] : []
    content {
      sid       = "AllowAlbLogDelivery"
      actions   = ["s3:PutObject"]
      resources = ["${each.value.arn}/alb/AWSLogs/${local.account_id}/*"]
      principals {
        type        = "AWS"
        identifiers = [data.aws_elb_service_account.main.arn]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each   = aws_s3_bucket.this
  bucket     = each.value.id
  policy     = data.aws_iam_policy_document.bucket[each.key].json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ---------------- container registries ----------------
resource "aws_ecr_repository" "this" {
  for_each             = local.ecr_repos
  name                 = "${var.project}/${each.key}"
  tags                 = { Name = "${var.project}/${each.key}", Component = each.key, Tier = "platform" }
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Drop untagged images after 7 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the latest 30 images"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
        action       = { type = "expire" }
      },
    ]
  })
}
