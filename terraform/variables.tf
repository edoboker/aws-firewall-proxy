variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-north-1"
}

variable "availability_zone" {
  description = "Single AZ for the deployment (must be within aws_region)"
  type        = string
  default     = "eu-north-1a"
}

variable "environment" {
  description = "Environment name used as a prefix for resource naming"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "workload_subnet_cidr" {
  description = "CIDR block for the workload subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "proxy_subnet_cidr" {
  description = "CIDR block for the proxy subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "firewall_subnet_cidr" {
  description = "CIDR block for the firewall subnet (ANF endpoint)"
  type        = string
  default     = "10.0.3.0/24"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (NAT Gateway)"
  type        = string
  default     = "10.0.4.0/24"
}

variable "proxy_instance_type" {
  description = "EC2 instance type for the nginx proxy"
  type        = string
  default     = "t3.small"
}

variable "workload_instance_type" {
  description = "EC2 instance type for the workload client"
  type        = string
  default     = "t3.micro"
}

variable "allowed_fqdns" {
  description = "FQDNs allowed through the network firewall (matched with dotprefix for subdomain safety)"
  type        = list(string)
  default     = ["google.com", "amazonaws.com", "cdn.amazonlinux.com"]
}

variable "nginx_allowed_snis" {
  description = "SNIs allowed by the on-host nginx gate. Pushed to SSM Parameter Store; the proxy refreshes every 60s."
  type        = list(string)
  default     = ["google.com", "amazonaws.com", "cdn.amazonlinux.com"]
}
