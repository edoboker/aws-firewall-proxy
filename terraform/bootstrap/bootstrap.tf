# Bootstrap: the S3 bucket that holds remote Terraform state for the other
# stacks (terraform/ and packer/build-infra/).
#
# Chicken-and-egg: this stack creates the state bucket, so it cannot store its
# own state in that bucket. It deliberately keeps LOCAL state and has no backend
# block. It is a one-time, rarely-touched stack.
#
# Usage:
#   terraform -chdir=terraform/bootstrap init
#   terraform -chdir=terraform/bootstrap apply
#   # then `terraform init -migrate-state` in terraform/ and packer/build-infra/.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  # Account id keeps the name globally unique. Must match the literal bucket name
  # hardcoded in the backend blocks of terraform/ and packer/build-infra/ (the
  # backend config cannot interpolate, so the two are kept in sync by hand).
  state_bucket_name = "aws-firewall-proxy-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name

  # State is the source of truth for every other stack; never let an apply here
  # delete it out from under them.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "aws-firewall-proxy-tfstate"
    Purpose = "terraform-remote-state"
  }
}

# Versioning is the recovery mechanism for corrupted or accidentally-overwritten
# state — keep it on.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Cap version sprawl: state is written on every apply, so old versions accumulate.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    # Empty filter = apply to all objects (required by the aws provider v6 schema).
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

output "state_bucket_name" {
  description = "Name of the S3 bucket holding remote Terraform state."
  value       = aws_s3_bucket.tfstate.id
}
