# ---------------------------------------------------------------------------
# ZTGW creation — fully automated via Terraform (no manual script step,
# no zsec wrapper required).
#
# Terraform cannot create the ZTGW directly (no official Zscaler ZTGW
# provider exists), so this wraps scripts/deploy_ztgw.sh using the
# local_file + null_resource pattern:
#
#   1. local_file.ztgw_input   -- writes the API payload as JSON, built
#                                  from this run's variables
#   2. null_resource.ztgw      -- runs scripts/deploy_ztgw.sh via
#                                  local-exec, feeding it ztgw_input's
#                                  content and capturing its output
#   3. data.local_file.ztgw_output -- reads the script's result back in
#
# This only executes during `terraform apply` (never `terraform plan`),
# and only re-runs if gateway_name or aws_region change (see triggers).
#
# NOTE: client_secret ends up in this file's content and therefore in
# Terraform state (.tfstate) in plaintext. Known/accepted tradeoff for
# the convenience of a single `terraform apply`.
# ---------------------------------------------------------------------------

resource "local_file" "ztgw_input" {
  count    = var.deploy_ztgw ? 1 : 0
  filename = "${path.module}/.ztgw-input.json"
  content = jsonencode({
    client_id               = var.client_id
    client_secret           = var.client_secret
    vanity_domain           = var.vanity_domain
    cloud                   = var.cloud
    login_domain            = var.login_domain
    gateway_name            = var.gateway_name
    aws_region              = var.aws_region
    aws_region_code         = var.aws_region_code
    availability_zone_ids   = var.availability_zone_ids
    location_name           = var.location_name
    allowed_accounts        = var.allowed_accounts
    account_groups          = var.account_groups
    additional_aws_accounts = var.additional_aws_accounts
  })
  file_permission = "0600"
}

resource "null_resource" "ztgw" {
  count = var.deploy_ztgw ? 1 : 0

  # Destroy-time provisioners can only reference self.triggers (not var.*
  # directly, since variables aren't guaranteed available during destroy),
  # so everything destroy_ztgw.sh needs is captured here at creation time.
  triggers = {
    gateway_name  = var.gateway_name
    aws_region    = var.aws_region
    client_id     = var.client_id
    client_secret = var.client_secret
    vanity_domain = var.vanity_domain
    cloud         = var.cloud
    login_domain  = var.login_domain
  }

  depends_on = [local_file.ztgw_input]

  # Create: runs deploy_ztgw.sh, which creates the gateway and polls until
  # healthy. Because aws_vpc_endpoint.consumer transitively depends on this
  # resource (via data.local_file.ztgw_output), Terraform destroys the VPC
  # Endpoints and their routes BEFORE this resource -- so by the time the
  # destroy provisioner below runs, nothing in AWS still references the
  # gateway's endpoint service.
  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/deploy_ztgw.sh < ${local_file.ztgw_input[0].filename} > ${path.module}/.ztgw-output.json"
  }

  # Destroy: deletes the gateway from Zscaler so `terraform destroy` does
  # the full job in one command, instead of requiring a separate manual
  # run of scripts/destroy_ztgw.sh afterward.
  provisioner "local-exec" {
    when    = destroy
    command = "TF_VAR_client_id='${self.triggers.client_id}' TF_VAR_client_secret='${self.triggers.client_secret}' TF_VAR_vanity_domain='${self.triggers.vanity_domain}' TF_VAR_cloud='${self.triggers.cloud}' TF_VAR_login_domain='${self.triggers.login_domain}' TF_VAR_gateway_name='${self.triggers.gateway_name}' bash ${path.module}/scripts/destroy_ztgw.sh"
  }
}

data "local_file" "ztgw_output" {
  count      = var.deploy_ztgw ? 1 : 0
  filename   = "${path.module}/.ztgw-output.json"
  depends_on = [null_resource.ztgw]
}

locals {
  ztgw_result           = var.deploy_ztgw ? jsondecode(data.local_file.ztgw_output[0].content) : null
  endpoint_service_name = try(local.ztgw_result.endpoint_service_name, var.endpoint_service_name)
}

# ---------------------------------------------------------------------------
# Consumer side: VPC Gateway Load Balancer Endpoint
#
# AWS requires exactly ONE subnet per GatewayLoadBalancer-type VPC Endpoint
# (unlike Interface endpoints, which accept a list of subnets in a single
# resource). For multi-AZ coverage, we create one endpoint PER subnet/AZ,
# each with its own route pointing to its own endpoint.
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "consumer" {
  count             = var.deploy_endpoint ? length(var.consumer_subnet_ids) : 0
  vpc_id            = var.consumer_vpc_id
  service_name      = local.endpoint_service_name
  vpc_endpoint_type = "GatewayLoadBalancer"
  subnet_ids        = [var.consumer_subnet_ids[count.index]]

  tags = {
    Name = "${var.consumer_deploy_key}-gwlbe-${count.index + 1}"
  }
}

data "aws_route_table" "subnet" {
  count     = var.deploy_endpoint ? length(var.consumer_subnet_ids) : 0
  subnet_id = var.consumer_subnet_ids[count.index]
}

resource "aws_route" "consumer" {
  count                  = var.deploy_endpoint ? length(var.consumer_subnet_ids) : 0
  route_table_id         = data.aws_route_table.subnet[count.index].id
  destination_cidr_block = var.consumer_route_cidr
  vpc_endpoint_id        = aws_vpc_endpoint.consumer[count.index].id

  depends_on = [aws_vpc_endpoint.consumer]
}
