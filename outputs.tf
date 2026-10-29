output "gateway_id" {
  description = "ID of the AWS ZTGW."
  value       = var.deploy_ztgw ? local.ztgw_result["gateway_id"] : null
}

output "gateway_name" {
  description = "Name of the AWS ZTGW."
  value       = var.deploy_ztgw ? local.ztgw_result["gateway_name"] : null
}

output "gateway_region" {
  description = "AWS region where the ZTGW is deployed."
  value       = var.deploy_ztgw ? local.ztgw_result["region"] : null
}

output "gateway_health_status" {
  description = "Health status of the AWS ZTGW."
  value       = var.deploy_ztgw ? local.ztgw_result["health_status"] : null
}

output "endpoint_service_name" {
  description = <<-EOT
    AWS VPC Endpoint Service Name for the ZTGW.
    Use this to create a Gateway Load Balancer Endpoint in your consumer VPC.
    EOT
  value       = var.deploy_ztgw ? local.ztgw_result["endpoint_service_name"] : null
}

output "endpoints_count" {
  description = "Number of connected VPC endpoints."
  value       = var.deploy_ztgw ? local.ztgw_result["endpoints_count"] : null
}

# ---------------------------------------------------------------------------
# Consumer-side outputs
# ---------------------------------------------------------------------------

output "vpc_endpoint_id" {
  description = "ID of the created VPC Gateway Load Balancer Endpoint."
  value       = var.deploy_endpoint ? aws_vpc_endpoint.consumer[0].id : null
}

output "vpc_endpoint_service_name" {
  description = "Endpoint service name used by the VPC Endpoint."
  value       = var.deploy_endpoint ? aws_vpc_endpoint.consumer[0].service_name : null
}

output "vpc_endpoint_state" {
  description = "State of the VPC Endpoint (e.g. Available, Pending, Failed)."
  value       = var.deploy_endpoint ? aws_vpc_endpoint.consumer[0].state : null
}

output "vpc_endpoint_route_table_ids" {
  description = "Route table IDs with routes pointing to the VPC Endpoint."
  value       = var.deploy_endpoint ? data.aws_route_table.subnet[*].id : null
}
