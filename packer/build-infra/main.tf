# Minimal VPC used only by Packer when building the proxy AMI. Kept separate
# from terraform/ (its own state) so the AMI build does not depend on, and is
# not coupled to, the main proxy stack.
#
# Usage:
#   cd packer/build-infra && terraform init && terraform apply
#   # Then feed the outputs to packer:
#   cd ../nginx-proxy
#   packer build \
#     -var "git_sha=$(git rev-parse --short HEAD)" \
#     -var "vpc_id=$(terraform -chdir=../build-infra output -raw vpc_id)" \
#     -var "subnet_id=$(terraform -chdir=../build-infra output -raw subnet_id)" \
#     .

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "availability_zone" {
  type    = string
  default = "eu-north-1a"
}

variable "name" {
  type    = string
  default = "packer-build"
}

provider "aws" {
  region = var.aws_region
}

resource "aws_vpc" "build" {
  cidr_block           = "10.99.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "build" {
  vpc_id = aws_vpc.build.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "build" {
  vpc_id                  = aws_vpc.build.id
  cidr_block              = "10.99.1.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public" }
}

resource "aws_route_table" "build" {
  vpc_id = aws_vpc.build.id
  tags   = { Name = var.name }
}

resource "aws_route" "default" {
  route_table_id         = aws_route_table.build.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.build.id
}

resource "aws_route_table_association" "build" {
  subnet_id      = aws_subnet.build.id
  route_table_id = aws_route_table.build.id
}

output "vpc_id" {
  value = aws_vpc.build.id
}

output "subnet_id" {
  value = aws_subnet.build.id
}
