# ---------------------------------------------------------------------------
# Deployment mode
# ---------------------------------------------------------------------------

variable "deploy_ztgw" {
  description = "Deploy a new AWS ZTGW."
  type        = bool
  default     = true
}

variable "deploy_endpoint" {
  description = "Deploy consumer-side VPC Gateway Load Balancer Endpoint."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Zscaler OneAPI authentication
# ---------------------------------------------------------------------------

variable "client_id" {
  description = "Zscaler OneAPI OAuth2 client ID."
  type        = string
}

variable "client_secret" {
  description = "Zscaler OneAPI OAuth2 client secret."
  type        = string
  sensitive   = true
}

variable "vanity_domain" {
  description = "Zscaler vanity domain (e.g. 'acme' -> acme.zslogin.net)."
  type        = string
}

variable "cloud" {
  description = "Zscaler cloud name: zscaler, zscalerone, zscalertwo, zscalerthree, zscalerbeta."
  type        = string
  default     = "zscalerbeta"
}

variable "login_domain" {
  description = <<-EOT
    Override OAuth2 login domain. Auto-derived from cloud if empty.
    Use 'zslogin.net' for tenants that authenticate through production login
    but use a different backend cloud.
    EOT
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# AWS ZTGW deployment parameters
# ---------------------------------------------------------------------------

variable "gateway_name" {
  description = "Name for the AWS Zero Trust Gateway."
  type        = string
  default     = "aws-ztgw"
}

variable "aws_region" {
  description = <<-EOT
    AWS region (e.g. us-west-2, us-east-1, eu-west-1).
    EOT
  type        = string
  default     = "us-west-2"
}

variable "aws_region_code" {
  description = <<-EOT
    AWS region code in Zscaler format (e.g. US_WEST_2, US_EAST_1, EU_WEST_1).
    This is the uppercase underscored version of the AWS region.
    EOT
  type        = string
  default     = "US_WEST_2"
}

variable "availability_zone_ids" {
  description = <<-EOT
    List of AWS Availability Zone IDs for the ZTGW.
    Leave empty to auto-discover via AWS CLI.
    Use the AZ ID format (e.g. usw2-az1, usw2-az2), not the AZ name.
    EOT
  type        = list(string)
  default     = []
}

variable "aws_endpoint_region" {
  description = "AWS region for the AWS provider and VPC Endpoint."
  type        = string
  default     = "us-west-2"
}

variable "location_name" {
  description = "Location name for the ZTGW (auto-created in Zscaler)."
  type        = string
  default     = "aws-ztgw-location"
}

variable "allowed_accounts" {
  description = <<-EOT
    List of Zscaler account IDs allowed to create VPC Endpoints to this ZTGW.
    These are configured in the Zscaler Admin Portal — get the IDs from there.
    Leave empty to skip (can be configured later in the portal).
    Example: [1591285, 462801]
    EOT
  type        = list(number)
  default     = []
}

variable "account_groups" {
  description = <<-EOT
    List of Zscaler account group IDs for this ZTGW.
    These are configured in the Zscaler Admin Portal — get the IDs from there.
    Leave empty to skip (can be configured later in the portal).
    Example: [1595528, 1173437]
    EOT
  type        = list(number)
  default     = []
}

variable "additional_aws_accounts" {
  description = <<-EOT
    List of AWS account IDs (12-digit) to whitelist for VPC endpoint connections
    to this ZTGW. These are the AWS account numbers that will be allowed to create
    Gateway Load Balancer Endpoints to the ZTGW endpoint service.
    Leave empty to skip (can be configured later in the Zscaler portal).
    Example: ["123456789012", "987654321098"]
    EOT
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Consumer-side VPC Endpoint (brownfield — user provides existing IDs)
# ---------------------------------------------------------------------------

variable "endpoint_service_name" {
  description = "Existing ZTGW endpoint service name. Required when deploy_ztgw = false and deploy_endpoint = true."
  type        = string
  default     = ""
}

variable "consumer_vpc_id" {
  description = "Existing VPC ID for the consumer VPC Endpoint."
  type        = string
  default     = ""
}

variable "consumer_subnet_ids" {
  description = "Existing subnet IDs for the consumer VPC Endpoint (one per AZ)."
  type        = list(string)
  default     = []
}

variable "consumer_route_cidr" {
  description = "Destination CIDR block for the VPC Endpoint route entries."
  type        = string
  default     = "0.0.0.0/0"
}

variable "consumer_deploy_key" {
  description = "Naming prefix for consumer-side resources."
  type        = string
  default     = "aws-ztgw"
}
