# One-time, run by a human with admin credentials, state kept locally (then commit nothing but this code):
#   terraform init && terraform apply -var github_repository=OWNER/REPO
# Creates the remote state bucket, the GitHub OIDC provider and the two Terraform CI roles.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "edupulse"
}

variable "owner" {
  type    = string
  default = "devops"
}

variable "cost_center" {
  type    = string
  default = "edupulse"
}

variable "github_repository" {
  description = "owner/repo whose workflows may run Terraform."
  type        = string
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = "shared"
      ManagedBy   = "terraform"
      Stack       = "bootstrap"
      Repository  = var.github_repository
      Owner       = var.owner
      CostCenter  = var.cost_center
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  bucket     = "${var.project}-tfstate-${local.account_id}-${var.region}"
}

# ---------------- remote state ----------------
resource "aws_s3_bucket" "state" {
  bucket = local.bucket
  tags   = { Name = local.bucket, Component = "terraform-state", Tier = "platform", DataClassification = "confidential" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
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
}

resource "aws_s3_bucket_policy" "state" {
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.state_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------- GitHub OIDC ----------------
resource "aws_iam_openid_connect_provider" "github" {
  tags            = { Name = "github-actions", Component = "ci", Tier = "platform" }
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "assume" {
  for_each = {
    # `plan` runs on main before approval; `apply` only after a human approves the `prod-infra` environment
    plan  = "repo:${var.github_repository}:environment:prod-infra-plan"
    apply = "repo:${var.github_repository}:environment:prod-infra"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "plan" {
  tags               = { Name = "${var.project}-terraform-plan", Component = "ci", Tier = "platform" }
  name               = "${var.project}-terraform-plan"
  assume_role_policy = data.aws_iam_policy_document.assume["plan"].json
}

resource "aws_iam_role" "apply" {
  tags               = { Name = "${var.project}-terraform-apply", Component = "ci", Tier = "platform" }
  name               = "${var.project}-terraform-apply"
  assume_role_policy = data.aws_iam_policy_document.assume["apply"].json
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Terraform's plan needs to read the generated secrets and to write its state lock.
data "aws_iam_policy_document" "plan_extra" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:${var.project}/*"]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
}

resource "aws_iam_role_policy" "plan_extra" {
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_extra.json
}

# Terraform creates IAM roles, VPCs, KMS keys and more, so apply needs broad rights.
# It is gated by a human approval. Narrow this to the services you actually manage.
resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "terraform_plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "terraform_apply_role_arn" {
  value = aws_iam_role.apply.arn
}
