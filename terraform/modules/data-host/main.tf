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

variable "subnet_id" {
  type = string
}

variable "availability_zone" {
  type = string
}

variable "private_ip" {
  description = "Fixed private IP: the data stores bind to it and DNS points at it."
  type        = string
}

variable "security_group_ids" {
  type = list(string)
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "root_volume_gb" {
  type    = number
  default = 20
}

variable "data_volume_gb" {
  type    = number
  default = 30
}

variable "kms_key_arn" {
  type = string
}

variable "artifacts_bucket" {
  description = "Bucket the pipeline syncs infra/ into (prefix infra/)."
  type        = string
}

variable "secret_arn" {
  description = "Secrets Manager secret with the data-tier credentials."
  type        = string
}

variable "compose_version" {
  type    = string
  default = "v2.29.7"
}

data "aws_region" "current" {}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# --- identity: SSM access (no SSH), read infra files, read its own secret ---
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "access" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.artifacts_bucket}/infra/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.artifacts_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["infra/*"]
    }
  }
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.secret_arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role" "this" {
  tags               = { Name = "${var.name}-data-host", Component = "data-host", Tier = "data" }
  name               = "${var.name}-data-host"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "access" {
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.access.json
}

resource "aws_iam_instance_profile" "this" {
  tags = { Name = "${var.name}-data-host", Component = "data-host", Tier = "data" }
  name = "${var.name}-data-host"
  role = aws_iam_role.this.name
}

# --- durable data disk, separate from the OS disk ---
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true
  kms_key_id        = var.kms_key_arn
  tags = {
    Name               = "${var.name}-data"
    Component          = "data-host"
    Tier               = "data"
    DataClassification = "confidential"
  }

  lifecycle {
    prevent_destroy = true # holds MySQL, Redis and RabbitMQ data
  }
}

resource "aws_instance" "this" {
  ami                    = nonsensitive(data.aws_ssm_parameter.al2023.value)
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  private_ip             = var.private_ip
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.this.name
  ebs_optimized          = true
  monitoring             = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers cannot reach instance credentials
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
    kms_key_id  = var.kms_key_arn
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    compose_version = var.compose_version
    volume_id       = replace(aws_ebs_volume.data.id, "-", "")
    bucket          = var.artifacts_bucket
    secret_id       = var.secret_arn
    region          = data.aws_region.current.name
    bind_ip         = var.private_ip
    deploy_script   = file("${path.module}/deploy-infra.sh")
  })

  tags = {
    Name      = var.name
    Component = "data-host"
    Tier      = "data"
  }

  # volumes created with the instance carry the same identity
  volume_tags = {
    Name      = "${var.name}-root"
    Component = "data-host"
    Tier      = "data"
  }

  lifecycle {
    # Replacing the host for every new AMI or boot-script edit would be disruptive.
    # Patch in place (SSM Patch Manager) or replace deliberately with -replace.
    ignore_changes = [ami, user_data]
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
}

output "instance_id" {
  value = aws_instance.this.id
}

output "private_ip" {
  value = aws_instance.this.private_ip
}

output "role_arn" {
  value = aws_iam_role.this.arn
}
