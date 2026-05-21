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
  default = "aws-firewall-proxy-nginx"
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
  description = "Subnet to launch the build instance in. Must be in packer_vpc_id and have a route to the internet (IGW or NAT) so packer can SSH in and so dnf can fetch packages."
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

source "amazon-ebs" "nginx_proxy" {
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
  sources = ["source.amazon-ebs.nginx_proxy"]

  provisioner "file" {
    source      = "${path.root}/files/nginx.conf"
    destination = "/tmp/nginx.conf"
  }

  provisioner "file" {
    source      = "${path.root}/files/refresh-sni-allowlist.sh"
    destination = "/tmp/refresh-sni-allowlist.sh"
  }

  provisioner "file" {
    source      = "${path.root}/files/refresh-sni-allowlist.service"
    destination = "/tmp/refresh-sni-allowlist.service"
  }

  provisioner "file" {
    source      = "${path.root}/files/refresh-sni-allowlist.timer"
    destination = "/tmp/refresh-sni-allowlist.timer"
  }

  provisioner "shell" {
    script          = "${path.root}/provision.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
}
