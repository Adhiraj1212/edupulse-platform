plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.38.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Tagging standard: these must be present on every taggable resource (directly or through the
# provider's default_tags). The pipeline fails when one is missing.
rule "aws_resource_missing_tags" {
  enabled = true
  tags    = ["Project", "Environment", "ManagedBy", "Stack", "Owner", "CostCenter"]
}
