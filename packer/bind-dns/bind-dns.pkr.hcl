packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.3"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "ami_name_prefix" {
  type    = string
  default = "aws-firewall-proxy-bind-dns"
}

variable "git_sha" {
  type        = string
  default     = "dev"
  description = "Git short SHA injected by the build runner; used as the AMI Version tag."
}

variable "packer_vpc_id" {
  type        = string
  default     = ""
  description = "VPC to launch the build instance in. Required when the account has no default VPC."
}

variable "packer_subnet_id" {
  type        = string
  default     = ""
  description = "Subnet to launch the build instance in. Must be in packer_vpc_id and route to the internet."
}

variable "bind_allow_query_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR allowed to query and recurse through BIND. Set this to the workload VPC CIDR."
}

variable "bind_min_cache_ttl" {
  type        = number
  default     = 90
  description = "Minimum positive-answer cache TTL in seconds. BIND caps min-cache-ttl at 90, so longer skew windows rely on serve-stale."
}

variable "bind_stale_answer_ttl" {
  type        = number
  default     = 30
  description = "TTL, in seconds, returned on stale answers when BIND serves stale cache data."
}

data "amazon-ami" "al2023" {
  filters = {
    name                = "al2023-ami-2023.*-x86_64"
    architecture        = "x86_64"
    virtualization-type = "hvm"
    root-device-type    = "ebs"
  }
  owners      = ["137112412989"]
  most_recent = true
  region      = var.aws_region
}

source "amazon-ebs" "bind_dns" {
  region                      = var.aws_region
  instance_type               = var.instance_type
  source_ami                  = data.amazon-ami.al2023.id
  ssh_username                = "ec2-user"
  ami_name                    = "${var.ami_name_prefix}-{{timestamp}}"
  associate_public_ip_address = true
  vpc_id                      = var.packer_vpc_id != "" ? var.packer_vpc_id : null
  subnet_id                   = var.packer_subnet_id != "" ? var.packer_subnet_id : null

  tags = {
    Name      = var.ami_name_prefix
    Version   = var.git_sha
    BuildDate = "{{isotime \"2006-01-02T15-04-05Z\"}}"
    BaseAMI   = "{{ .SourceAMI }}"
  }
}

build {
  sources = ["source.amazon-ebs.bind_dns"]

  provisioner "file" {
    source      = "${path.root}/assets"
    destination = "/tmp/"
  }

  provisioner "shell" {
    script = "${path.root}/provision.sh"
    environment_vars = [
      "BIND_ALLOW_QUERY_CIDR=${var.bind_allow_query_cidr}",
      "BIND_MIN_CACHE_TTL=${var.bind_min_cache_ttl}",
      "BIND_STALE_ANSWER_TTL=${var.bind_stale_answer_ttl}",
    ]
    execute_command = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
  }
}
