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

variable "direct_workload_subnet_cidr" {
  description = "CIDR block for the no-proxy workload subnet that routes directly through AWS Network Firewall"
  type        = string
  default     = "10.0.5.0/24"
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

variable "enable_dns_firewall" {
  description = "Associate the Route 53 Resolver DNS Firewall rule group with the workload VPC. Disable temporarily when debugging resolver forwarding or CNAME behavior; the firewall lists/rules remain managed."
  type        = bool
  default     = true
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
  default     = 20

  validation {
    condition     = var.proxy_metrics_publish_interval_seconds >= 10 && var.proxy_metrics_publish_interval_seconds <= 900 && floor(var.proxy_metrics_publish_interval_seconds) == var.proxy_metrics_publish_interval_seconds
    error_message = "Proxy metrics publish interval must be an integer between 10 and 900 seconds."
  }
}

variable "enable_lambda_ip_fallback" {
  description = "Provision the experimental parallel ruleset-generator resources in the main stack and attach their IP-set-backed TLS rule group to the main firewall policy."
  type        = bool
  default     = false
}

variable "lambda_ip_fallback_fqdns" {
  description = "Exact FQDNs resolved by the parallel ruleset-generator MVP."
  type        = list(string)
  default     = ["login.microsoftonline.com", "wiz.io"]
}

variable "lambda_ip_fallback_max_addresses_per_fqdn" {
  description = "Maximum number of IPv4 addresses to publish for each ruleset-generator FQDN."
  type        = number
  default     = 16

  validation {
    condition     = var.lambda_ip_fallback_max_addresses_per_fqdn >= 1 && var.lambda_ip_fallback_max_addresses_per_fqdn <= 64
    error_message = "lambda_ip_fallback_max_addresses_per_fqdn must be between 1 and 64."
  }
}

variable "lambda_ip_fallback_prefix_list_max_entries" {
  description = "Maximum entries per ruleset-generator managed prefix list. Additional prefix lists are created when the FQDN/address cap exceeds this value."
  type        = number
  default     = 1000

  validation {
    condition     = var.lambda_ip_fallback_prefix_list_max_entries >= 1 && var.lambda_ip_fallback_prefix_list_max_entries <= 1000
    error_message = "lambda_ip_fallback_prefix_list_max_entries must be between 1 and 1000."
  }
}

variable "lambda_ip_fallback_timeout_seconds" {
  description = "Timeout for the parallel ruleset-generator Lambda."
  type        = number
  default     = 30
}

variable "enable_lambda_ip_fallback_schedule" {
  description = "Create an EventBridge schedule for the parallel ruleset-generator Lambda. The Lambda can still be invoked manually when false."
  type        = bool
  default     = false
}

variable "lambda_ip_fallback_schedule_expression" {
  description = "EventBridge schedule expression for the parallel ruleset-generator Lambda when scheduling is enabled."
  type        = string
  default     = "rate(5 minutes)"
}
