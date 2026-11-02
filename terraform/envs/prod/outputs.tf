output "app_urls" {
  value = [for h in local.app_hostnames : "https://${h}"]
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "nat_public_ips" {
  description = "Egress IPs of the private subnets (allow-list these at third parties)."
  value       = module.vpc.nat_public_ips
}

output "ecr_repositories" {
  value = local.repo_url
}

output "data_host_instance_id" {
  value = module.data_host.instance_id
}

output "app_secret_names" {
  description = "Read admin/student passwords from the auth secret (ADMIN_PASSWORD, STUDENT_PASSWORD)."
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.name }
}

# Paste these into GitHub: Settings > Secrets and variables > Actions > Variables
output "github_actions_variables" {
  value = {
    AWS_REGION        = var.region
    AWS_ROLE_PUSH     = aws_iam_role.gh_push.arn
    AWS_ROLE_DEPLOY   = aws_iam_role.gh_deploy.arn
    ECS_CLUSTER       = aws_ecs_cluster.this.name
    ECR_REGISTRY      = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
    ARTIFACTS_BUCKET  = aws_s3_bucket.this["artifacts"].id
    INFRA_INSTANCE_ID = module.data_host.instance_id
  }
}
