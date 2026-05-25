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

variable "proxy_dns_mode" {
  description = "Proxy DNS resolution attitude. `fanout` queries multiple resolvers repeatedly to widen the observed RRset; `shared-cache` resolves once through the VPC .2 resolver only, relying on the shared BIND9 cache (docs/shared-dns-cache.md) for completeness. Switching to `shared-cache` is meaningful only once the Resolver forwarding path (T4) is in place."
  type        = string
  default     = "fanout"

  validation {
    condition     = contains(["fanout", "shared-cache"], var.proxy_dns_mode)
    error_message = "Proxy DNS mode must be either fanout or shared-cache."
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

# ── Shared-DNS feature (docs/shared-dns-cache.md) ─────────────────────────────

variable "enable_shared_dns" {
  description = "Provision the shared-DNS stack: a dedicated DNS VPC and a BIND9 recursive resolver (T2), and in later tasks the Route 53 Resolver forwarding path. Off by default so the existing single-VPC deployment is unaffected. Requires the BIND9 AMI (packer/bind-dns) to exist before enabling."
  type        = bool
  default     = false
}

variable "dns_vpc_cidr" {
  description = "CIDR block for the dedicated DNS VPC that hosts BIND9. Must not overlap var.vpc_cidr (the two are peered in T3)."
  type        = string
  default     = "10.1.0.0/16"
}

variable "dns_private_subnet_cidr" {
  description = "CIDR for the private subnet that holds the BIND9 instance."
  type        = string
  default     = "10.1.1.0/24"
}

variable "bind_instance_type" {
  description = "EC2 instance type for the BIND9 resolver."
  type        = string
  default     = "t3.micro"
}

variable "bind_min_cache_ttl" {
  description = "Floor (seconds) for how long BIND9 caches an RRset even when the authoritative TTL is shorter, so the proxy's follow-up resolution sees the same RRset the client did (docs/shared-dns-cache.md §4.1). Passed to the BIND9 AMI via /etc/sysconfig/bind-tuning."
  type        = number
  default     = 30
}

variable "forwarded_domains" {
  description = "Domain suffixes forwarded from the workload VPC resolver to BIND9 in shared-DNS mode. Empty means use allowed_fqdns. Autodefined Resolver rules such as AWS internal names may still resolve locally unless overridden by an equally specific conditional forwarding rule."
  type        = list(string)
  default     = []
}
