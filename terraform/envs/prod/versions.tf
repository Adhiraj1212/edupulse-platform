terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.52"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Created by terraform/bootstrap. Settings come from backend.hcl:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {}
}

# Token comes from the CLOUDFLARE_API_TOKEN environment variable (Zone > DNS > Edit, this zone only).
provider "cloudflare" {}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}
