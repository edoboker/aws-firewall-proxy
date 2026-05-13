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

output "envoy_instance_id" {
  description = "Instance ID of the Envoy proxy EC2"
  value       = aws_instance.envoy.id
}

output "envoy_private_ip" {
  description = "Private IP of the Envoy proxy EC2"
  value       = aws_instance.envoy.private_ip
}
