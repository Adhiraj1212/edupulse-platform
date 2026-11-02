#!/usr/bin/env bash
# Proves the required-tags rule bites: an untagged bucket MUST fail, a tagged one MUST pass.
set -u
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
cp terraform/.tflint.hcl "$T/"
cat > "$T/main.tf" <<'TF'
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_s3_bucket" "untagged" {
  bucket = "demo-untagged"
}
TF
run() { docker run --rm -v "$T":/data -w /data --entrypoint sh ghcr.io/terraform-linters/tflint:latest -c "tflint --init >/dev/null && tflint"; }
OUT=$(run 2>&1); if echo "$OUT" | grep -q "aws_resource_missing_tags"; then echo "ok: untagged bucket rejected by the tags rule"; rc=0; else echo "FAIL: tags rule did not fire"; echo "$OUT"; rc=1; fi
cat > "$T/main.tf" <<'TF'
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  default_tags {
    tags = { Project = "p", Environment = "e", ManagedBy = "terraform", Stack = "s", Owner = "o", CostCenter = "c" }
  }
}
resource "aws_s3_bucket" "tagged" {
  bucket = "demo-tagged"
}
TF
OUT=$(run 2>&1); if echo "$OUT" | grep -q "aws_resource_missing_tags"; then echo "FAIL: default_tags not honoured"; echo "$OUT"; rc=1; else echo "ok: bucket tagged via default_tags accepted"; fi
rm -rf "$T"
exit $rc
