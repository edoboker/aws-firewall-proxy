output "proxy_instance_id" {
  description = "Instance ID of the nginx proxy EC2"
  value       = aws_instance.proxy.id
}

output "proxy_private_ip" {
  description = "Private IP of the nginx proxy EC2"
  value       = aws_instance.proxy.private_ip
}

output "workload_instance_id" {
  description = "Instance ID of the workload client EC2"
  value       = aws_instance.workload.id
}

output "allowed_fqdns" {
  description = "FQDNs the proxy chain permits — consumed by the test harness"
  value       = var.allowed_fqdns
}
