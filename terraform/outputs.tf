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
  description = "FQDNs the proxy chain permits - consumed by the test harness"
  value       = var.allowed_fqdns
}

output "nginx_allowed_snis" {
  description = "SNIs allowed by the on-host nginx/OpenResty guard - consumed by the test harness"
  value       = var.nginx_allowed_snis
}

output "aws_region" {
  description = "Region the stack is deployed in - consumed by the test/benchmark harness"
  value       = var.aws_region
}

output "proxy_runtime_policy_appconfig_path" {
  description = "AppConfig application/environment/profile path for the proxy runtime policy"
  value       = "${aws_appconfig_application.proxy.name}/${aws_appconfig_environment.proxy.name}/${aws_appconfig_configuration_profile.proxy_runtime_policy.name}"
}

# Consumed by benchmark/run.py to swap the workload default route between the
# proxy ENI (proxied path) and the ANF endpoint (baseline path).
output "workload_route_table_id" {
  description = "Route table whose 0.0.0.0/0 entry steers workload egress through the proxy"
  value       = aws_route_table.workload.id
}

output "proxy_eni_id" {
  description = "Primary ENI of the nginx proxy - the proxied route's next hop"
  value       = aws_instance.proxy.primary_network_interface_id
}

output "anf_endpoint_id" {
  description = "ANF VPC endpoint ID - the baseline (no-proxy) route's next hop"
  value       = local.anf_endpoint_id
}
