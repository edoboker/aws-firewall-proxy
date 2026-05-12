variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "availability_zone" {
  type    = string
  default = "us-east-1a"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "workload_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "proxy_subnet_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

variable "firewall_subnet_cidr" {
  type    = string
  default = "10.0.3.0/24"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.4.0/24"
}

variable "proxy_instance_type" {
  type    = string
  default = "t3.small"
}

variable "envoy_instance_type" {
  type    = string
  default = "t3.small"
}

variable "workload_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "allowed_fqdns" {
  type    = list(string)
  default = ["google.com", "amazonaws.com"]
}
