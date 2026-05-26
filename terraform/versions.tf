terraform {
  required_version = ">= 1.6"

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }

    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Remote state in the bucket created by terraform/bootstrap. Distinct key from
  # terraform/packer-bootstrap (separate state file, separate per-key lock). S3-native
  # locking (use_lockfile) requires Terraform >= 1.10 — no DynamoDB table needed.
  backend "s3" {
    bucket       = "aws-firewall-proxy-tfstate-067438588597"
    key          = "firewall-proxy/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}
