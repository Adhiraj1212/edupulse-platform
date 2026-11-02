# GitHub Actions authenticates with short-lived OIDC tokens: no AWS keys are stored anywhere.
# The OIDC provider itself is created once in terraform/bootstrap.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  gh_repo = var.github_repository
}

data "aws_iam_policy_document" "gh_assume" {
  for_each = {
    # build + push images: only from the protected branch
    push = ["repo:${local.gh_repo}:ref:refs/heads/${var.github_branch}"]
    # deploy to ECS / infra host: only jobs that passed the `prod` environment approval
    deploy = ["repo:${local.gh_repo}:environment:prod"]
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "gh_push" {
  tags               = { Name = "${local.name}-gh-push", Component = "ci", Tier = "platform" }
  name               = "${local.name}-gh-push"
  assume_role_policy = data.aws_iam_policy_document.gh_assume["push"].json
}

resource "aws_iam_role" "gh_deploy" {
  tags               = { Name = "${local.name}-gh-deploy", Component = "ci", Tier = "platform" }
  name               = "${local.name}-gh-deploy"
  assume_role_policy = data.aws_iam_policy_document.gh_assume["deploy"].json
}

data "aws_iam_policy_document" "gh_push" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages",
    ]
    resources = [for r in aws_ecr_repository.this : r.arn]
  }
}

data "aws_iam_policy_document" "gh_deploy" {
  statement {
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = [for s in local.ecs_services : s.service_arn]
  }
  statement {
    # task definition actions do not support resource-level permissions
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }
  statement {
    actions = ["iam:PassRole"]
    resources = flatten([
      for s in local.ecs_services : [s.execution_role_arn, s.task_role_arn]
    ])
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
  # infra pipeline: publish files to S3 and run the deploy script on the data host
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.this["artifacts"].arn}/infra/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this["artifacts"].arn]
  }
  statement {
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
  statement {
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.name}:${local.account_id}:instance/${module.data_host.instance_id}",
      "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript",
    ]
  }
  statement {
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gh_push" {
  role   = aws_iam_role.gh_push.id
  policy = data.aws_iam_policy_document.gh_push.json
}

resource "aws_iam_role_policy" "gh_deploy" {
  role   = aws_iam_role.gh_deploy.id
  policy = data.aws_iam_policy_document.gh_deploy.json
}
