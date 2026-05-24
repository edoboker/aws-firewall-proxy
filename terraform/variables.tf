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
  description = "SNIs allowed by the on-host nginx/OpenResty guard. Terraform publishes them into the AppConfig runtime policy."
  type        = list(string)
  default     = ["google.com", "amazonaws.com", "cdn.amazonlinux.com"]
}

variable "proxy_public_dns_resolvers" {
  description = "Public DNS resolver IPs the demo firewall policy allows the proxy to query directly."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "proxy_dns_queries_per_sni" {
  description = "How many A-record queries the proxy sends to each configured resolver for each SNI."
  type        = number
  default     = 3

  validation {
    condition     = var.proxy_dns_queries_per_sni >= 1 && var.proxy_dns_queries_per_sni <= 16
    error_message = "Proxy DNS queries per SNI must be between 1 and 16."
  }
}

variable "proxy_enforcement_mode" {
  description = "Whether the on-host proxy enforces mismatches (`strict`) or only logs them (`audit`)."
  type        = string
  default     = "strict"

  validation {
    condition     = contains(["strict", "audit"], var.proxy_enforcement_mode)
    error_message = "Proxy enforcement mode must be either strict or audit."
  }
}

variable "proxy_metrics_publish_interval_seconds" {
  description = "How often the proxy flushes aggregated metrics to the local CloudWatch agent StatsD listener."
  type        = number
  default     = 60

  validation {
    condition     = var.proxy_metrics_publish_interval_seconds >= 10 && var.proxy_metrics_publish_interval_seconds <= 900 && floor(var.proxy_metrics_publish_interval_seconds) == var.proxy_metrics_publish_interval_seconds
    error_message = "Proxy metrics publish interval must be an integer between 10 and 900 seconds."
  }
}
