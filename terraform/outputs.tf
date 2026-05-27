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

output "direct_workload_instance_id" {
  description = "Instance ID of the no-proxy workload client EC2"
  value       = aws_instance.direct_workload.id
}

output "allowed_fqdns" {
  description = "FQDNs the proxy chain permits - consumed by the test harness"
  value       = var.allowed_fqdns
}

output "http_allowed_hosts" {
  description = "Hosts allowed by the experimental HTTP Host/original-dst guard"
  value       = var.http_allowed_hosts
}

output "aws_region" {
  description = "Region the stack is deployed in - consumed by the test/benchmark harness"
  value       = var.aws_region
}

output "http_enforcement_mode" {
  description = "Experimental HTTP guard enforcement mode (strict|audit)"
  value       = var.http_enforcement_mode
}

output "proxy_runtime_policy_appconfig_path" {
  description = "AppConfig application/environment/profile path for the proxy runtime policy"
  value       = "${aws_appconfig_application.proxy.name}/${aws_appconfig_environment.proxy.name}/${aws_appconfig_configuration_profile.proxy_runtime_policy.name}"
}

# Consumed by benchmark/workload_bench/run.py to swap the workload default route between the
# proxy ENI (proxied path) and the ANF endpoint (baseline path).
output "workload_route_table_id" {
  description = "Route table whose 0.0.0.0/0 entry steers workload egress through the proxy"
  value       = aws_route_table.workload.id
}

output "direct_workload_route_table_id" {
  description = "Route table whose 0.0.0.0/0 entry steers the no-proxy workload directly through ANF"
  value       = aws_route_table.direct_workload.id
}

output "proxy_eni_id" {
  description = "Primary ENI of the nginx proxy - the proxied route's next hop"
  value       = aws_instance.proxy.primary_network_interface_id
}

output "anf_endpoint_id" {
  description = "ANF VPC endpoint ID - the baseline (no-proxy) route's next hop"
  value       = local.anf_endpoint_id
}

output "ruleset_generator_prefix_list_id" {
  description = "First managed prefix list updated by the parallel ruleset-generator Lambda; null unless enabled"
  value       = var.enable_ruleset_generator ? values(aws_ec2_managed_prefix_list.ruleset_generator)[0].id : null
}

output "ruleset_generator_prefix_list_ids" {
  description = "All managed prefix lists updated by the parallel ruleset-generator Lambda; empty unless enabled"
  value       = var.enable_ruleset_generator ? [for prefix_list in values(aws_ec2_managed_prefix_list.ruleset_generator) : prefix_list.id] : []
}

output "ruleset_generator_prefix_list_ids_by_fqdn" {
  description = "Managed prefix list IDs by exact ruleset-generator FQDN; empty unless enabled"
  value       = var.enable_ruleset_generator ? { for fqdn, prefix_list in aws_ec2_managed_prefix_list.ruleset_generator : fqdn => prefix_list.id } : {}
}

output "ruleset_generator_rule_group_arn" {
  description = "Network Firewall rule group ARN for the parallel ruleset-generator path; null unless enabled"
  value       = var.enable_ruleset_generator ? aws_networkfirewall_rule_group.ruleset_generator[0].arn : null
}

output "ruleset_generator_function_name" {
  description = "Parallel ruleset-generator Lambda function name; null unless enabled"
  value       = var.enable_ruleset_generator ? aws_lambda_function.ruleset_generator[0].function_name : null
}
