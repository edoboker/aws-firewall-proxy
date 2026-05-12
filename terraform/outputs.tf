output "proxy_instance_id" {
  value = aws_instance.proxy.id
}

output "proxy_private_ip" {
  value = aws_instance.proxy.private_ip
}

output "workload_instance_id" {
  value = aws_instance.workload.id
}
