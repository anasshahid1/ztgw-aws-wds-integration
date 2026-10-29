# Zscaler AWS ZTGW — Terraform Deployment

Provision an **AWS Zero Trust Gateway** (ZTGW) via the Zscaler REST API and optionally create a **VPC Gateway Load Balancer Endpoint** in your existing VPC — all from a single Terraform workflow.

Two supported ways to run it:
1. **Pure Terraform** (`terraform apply` only, no wrapper) — recommended if you want everything driven by a single `.tfvars` file.
2. **Interactive wrapper** (`./zsec up`) — guided prompts, config caching, good for first-time/manual use.

---

## Architecture

```
terraform apply
      │
      ▼
local_file.ztgw_input ──► writes .ztgw-input.json (API payload from your .tfvars)
      │
      ▼
null_resource.ztgw (local-exec) ──► runs scripts/deploy_ztgw.sh
      │                                   │
      │                                   ▼
      │                            Zscaler OneAPI: authenticate,
      │                            create ZTGW, poll until HEALTHY,
      │                            force activation
      │                                   │
      │                                   ▼
      │                            writes .ztgw-output.json
      ▼
data.local_file.ztgw_output ──► reads endpoint_service_name back into Terraform
      │
      ▼
aws_vpc_endpoint (GatewayLoadBalancer, ONE per subnet/AZ)
      │
      ▼
data.aws_route_table (auto-discovered per subnet)
      │
      ▼
aws_route (0.0.0.0/0 → its own AZ's vpce-xxx)
```

> **Note:** AWS requires exactly **one subnet per GatewayLoadBalancer-type VPC Endpoint** (unlike Interface endpoints, which accept multiple). This repo creates one `aws_vpc_endpoint` + one `aws_route` per subnet/AZ you provide — not a single multi-subnet resource.

---

## Features

- **Two workflows**: pure `terraform apply` (via `null_resource` + `local_file`) or interactive `./zsec up`
- **3 deployment modes**: Full, ZTGW-only, Endpoint-only
- **AZ auto-discovery**: Uses AWS CLI to discover availability zone IDs per region
- **Force activation**: Triggers Zscaler activation after deploy and destroy
- **Brownfield consumer**: Bring your own VPC, subnets, and route CIDR — route tables are auto-discovered
- **Per-AZ GWLB Endpoints**: one endpoint + one route per subnet, correctly matching AWS's GWLB constraints
- **Interactive WDS account/group selection** (`zsec` only): queries your Zscaler tenant for already-onboarded Workload Discovery Service (Tag Discovery) accounts and account groups, and lets you pick which ones to link to this gateway's `allowed_accounts`/`account_groups` — no need to already know their numeric Zscaler IDs by heart
- **No docs needed**: API schema was reverse-engineered from the live Zscaler API

### WDS account/group selection (zsec only)

When running `./zsec up` in a mode that creates a gateway, right after you enter your Zscaler credentials, the wizard authenticates and queries `GET /publicCloudInfo` (AWS accounts onboarded to Workload Discovery) and `GET /accountGroups` (existing account groups), then presents both as numbered, selectable lists:

```
--- Workload Discovery Service (WDS) Account/Group Selection ---
Onboarded WDS accounts found:
  1) prod-aws (123456789012) - Zscaler ID 1234567
  2) staging-aws (987654321098) - Zscaler ID 7654321
Select accounts to link as allowed_accounts (comma-separated numbers, Enter to skip):
```

Your selections are written directly into `allowed_accounts`/`account_groups` in `.zsecrc`, then flow into the real gateway creation payload. If the query fails (auth issue, network, or you just don't see what you need in the list), you'll still get the original manual numeric-ID entry prompt as a fallback — nothing is lost, this just adds a more convenient path on top.

This is `zsec`-only, not available in the pure-Terraform workflow, since `.tfvars` files are static and there's no natural place for an interactive "pick from a live list" step there. If you already know the Zscaler IDs you want, just set `allowed_accounts`/`account_groups` directly in your `.tfvars` file.

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| Python 3 | JSON parsing in shell scripts |
| AWS CLI | AZ discovery, credentials for VPC Endpoint |
| Terraform >= 1.0 | Infrastructure orchestration |
| Zscaler OneAPI OAuth2 credentials | Client ID, Client Secret, Vanity Domain |

---

## Quick Start — Pure Terraform (recommended)

```bash
git clone https://github.com/<your-org>/ztgw-automation-aws-customer
cd ztgw-automation-aws-customer
cp ztgw-full-deploy.tfvars.example ztgw-full-deploy.tfvars
# edit ztgw-full-deploy.tfvars with your real values (never commit this file)

terraform init
terraform apply -var-file=ztgw-full-deploy.tfvars
```

That's it. A single `terraform apply` will:
1. Write the gateway API payload to `.ztgw-input.json`
2. Automatically run `scripts/deploy_ztgw.sh` (via a `local-exec` provisioner), which creates the ZT Gateway and polls until it's `HEALTHY` (can take several minutes — progress prints to your terminal)
3. Read the result back from `.ztgw-output.json`
4. Create the VPC Gateway Load Balancer Endpoint(s) + routes in your existing VPC

**Important:** `client_secret` ends up in Terraform state (`.tfstate`) in plaintext via `local_file.ztgw_input`. This is a known, accepted tradeoff for the convenience of a single `terraform apply` — don't commit your `.tfstate` file, and treat it as sensitive.

`terraform destroy` will remove the AWS-side resources (VPC Endpoint, routes) but **does not** currently delete the ZT Gateway from Zscaler (no destroy-time provisioner is wired up yet — see Destroy section below).

---

## Quick Start — Interactive wrapper (`zsec`)

```bash
git clone https://github.com/<your-org>/ztgw-automation-aws-customer
cd ztgw-automation-aws-customer
./zsec up
```

Follow the interactive prompts. On first run, `./zsec up` will:

1. Ask your deployment mode (Full / ZTGW-only / Endpoint-only)
2. Prompt for Zscaler OneAPI credentials
3. Prompt for AWS region, ZTGW name, and ZTGW configuration
4. Auto-discover AZs via AWS CLI
5. Prompt for consumer VPC details (if deploying endpoint)
6. Show a summary and ask for confirmation
7. Run `terraform init && terraform apply`

Configuration is cached in `.zsecrc`. Re-run `./zsec up` to apply with the same config — it will skip the interactive prompts since `.zsecrc` already exists.

---

## Deployment Modes

| Mode | `deploy_ztgw` | `deploy_endpoint` | What happens |
|------|:---:|:---:|---|
| **Full** | `true` | `true` | Create ZTGW → get endpoint service name → create VPC Endpoint(s) + routes |
| **ZTGW-only** | `true` | `false` | Create ZTGW, output `endpoint_service_name` |
| **Endpoint-only** | `false` | `true` | Create VPC Endpoint(s) from an existing `endpoint_service_name` |

---

## Variables

### Authentication

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `client_id` | `string` | — | Zscaler OneAPI OAuth2 client ID |
| `client_secret` | `string` (sensitive) | — | Zscaler OneAPI OAuth2 client secret |
| `vanity_domain` | `string` | — | Zscaler vanity domain (e.g. `acme` → `acme.zslogin.net`) |
| `cloud` | `string` | `zscalerbeta` | Zscaler cloud: `zscaler`, `zscalerone`, `zscalertwo`, `zscalerthree`, `zscalerbeta` |
| `login_domain` | `string` | `""` | Override OAuth2 login domain. Auto-derived from cloud if empty. Some tenants authenticate through the production login (`zslogin.net`) instead of their cloud-specific domain — if auth fails with a DNS error, try setting this explicitly. |

### ZTGW

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `gateway_name` | `string` | `aws-ztgw` | ZTGW name |
| `location_name` | `string` | `aws-ztgw-location` | Zscaler location name (must be unique — see Troubleshooting) |
| `aws_region` | `string` | `us-west-2` | AWS region |
| `aws_region_code` | `string` | `US_WEST_2` | AWS region in Zscaler format (uppercase underscored) |
| `availability_zone_ids` | `list(string)` | `[]` | AZ IDs (auto-discovered via AWS CLI if empty) |
| `allowed_accounts` | `list(number)` | `[]` | Zscaler account IDs for endpoint service (optional) |
| `account_groups` | `list(number)` | `[]` | Zscaler account group IDs (optional) |
| `additional_aws_accounts` | `list(string)` | `[]` | AWS account IDs (12-digit) to whitelist for VPC endpoint connections (optional) |

### Consumer VPC Endpoint

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `deploy_endpoint` | `bool` | `true` | Deploy consumer VPC Endpoint(s) |
| `endpoint_service_name` | `string` | `""` | Existing endpoint service (required in Endpoint-only mode) |
| `consumer_vpc_id` | `string` | `""` | Existing VPC ID |
| `consumer_subnet_ids` | `list(string)` | `[]` | Existing subnet IDs, one per AZ — one GWLB Endpoint + one route is created per subnet |
| `consumer_route_cidr` | `string` | `0.0.0.0/0` | Destination CIDR for each VPC Endpoint's route |
| `consumer_deploy_key` | `string` | `aws-ztgw` | Naming prefix for resources |
| `aws_endpoint_region` | `string` | `us-west-2` | AWS region for the AWS provider |

---

## Outputs

| Output | Description |
|--------|-------------|
| `gateway_id` | ZTGW ID in Zscaler |
| `gateway_name` | ZTGW name |
| `gateway_region` | AWS region |
| `gateway_health_status` | Health status (HEALTHY, INIT, etc.) |
| `endpoint_service_name` | **VPC Endpoint Service name** — use this to create GWLB Endpoints |
| `endpoints_count` | Number of connected VPC Endpoints |
| `vpc_endpoint_id` | ID of the first created VPC Endpoint |
| `vpc_endpoint_service_name` | Service name used by the endpoint |
| `vpc_endpoint_state` | State (Available, Pending, etc.) |
| `vpc_endpoint_route_table_ids` | Route tables with endpoint routes |

---

## Destroy

### Via Terraform (pure workflow)
```bash
terraform destroy -var-file=ztgw-full-deploy.tfvars
```
A single `terraform destroy` now handles the full lifecycle in the correct order:
1. `aws_route.consumer` — routes removed first
2. `aws_vpc_endpoint.consumer` — VPC Endpoint(s) removed next (this order is guaranteed by the dependency chain: endpoints reference `data.local_file.ztgw_output`, which `depends_on` `null_resource.ztgw`, so Terraform destroys endpoints before the gateway)
3. `null_resource.ztgw`'s destroy-time provisioner deletes the actual ZT Gateway from Zscaler via `scripts/destroy_ztgw.sh`
4. `local_file.ztgw_input` cleaned up last

No manual script invocation needed — the gateway's credentials and name are captured in `triggers` at creation time specifically so they're available to the destroy-time provisioner later (destroy-time provisioners can only reference `self.triggers`, not `var.*` directly).

**Known tradeoff:** this means `client_secret` is also stored in `triggers` (in addition to `local_file.ztgw_input`'s content) — both end up in Terraform state in plaintext. Same accepted tradeoff as the create path, just extended to cover destroy too.

**Important:** deleting a gateway (via this flow, via `destroy_ztgw.sh` directly, or via the Admin UI) does **not** clean up its associated Location object. If you reuse the same `location_name` for a new gateway afterward, creation may fail with `INVALID_INPUT_ARGUMENT: Mentioned location name already exists`. Use a different `location_name` if this happens — this is a Zscaler API gap, not something this repo's code currently works around.

### Via zsec
```bash
./zsec destroy
```
The destroy flow:
1. **Delete ZTGW** via Zscaler REST API → sleep 10s → force activation
2. **Terraform destroy** — removes VPC Endpoint, routes, and state
3. **Cleanup** — removes `.terraform/`, state files, `bin/`, archives `.zsecrc`

---

## Troubleshooting

### `INVALID_OPERATION: Cannot create Zero Trust Gateway while there are pending activation changes`

A prior change (e.g. a gateway deletion) hasn't been activated yet. Either activate pending changes manually in the Zscaler Admin Portal, or retry the force-activation call.

### `INVALID_INPUT_ARGUMENT: Mentioned location name already exists`

The Location object tied to a previously-deleted gateway wasn't cleaned up (this can happen even via `destroy_ztgw.sh`, which only deletes the gateway, not its Location). Use a different `location_name`, or manually find/delete the orphaned Location via `GET /location` against `https://connector.<cloud>.net/api/v1/location`.

### `Only one subnet can be specified for GatewayLoadBalancer type VPC Endpoint`

Already handled in this repo's `main.tf` — each subnet gets its own `aws_vpc_endpoint` + `aws_route`. If you see this error, you're likely running older code that passed a full subnet list to a single endpoint resource.

### `RouteAlreadyExists`

The destination CIDR (commonly `0.0.0.0/0`) already has a route in that route table — e.g. an existing Internet Gateway or NAT Gateway default route. You can't have two `0.0.0.0/0` routes in the same table. Either use dedicated subnets/route tables for the GWLB Endpoint traffic, or deliberately replace the existing route (requires `terraform import` of the existing route first).

### Force Activation returns `NON_SUPER_ADMIN_FORCED_ACTIVATE_NOT_ALLOWED`

Expected on `zscalerbeta` and non-super-admin accounts. The activation call is made but requires super admin privileges on production Zscaler clouds. The ZTGW itself is still fully functional.

### ZTGW stuck in `INIT` state

ZTGW provisioning typically takes 3–5 minutes. The script polls for up to 10 minutes. If it times out, the ZTGW may still be provisioning in the background — just re-run `terraform apply` (or `./zsec up`) again to pick up the existing gateway and resume health-checking.

### AWS CLI not available

Without AWS CLI, AZ auto-discovery falls back to the `availability_zone_ids` variable. Set it explicitly:

```hcl
availability_zone_ids = ["usw2-az1", "usw2-az2"]
```

---

## Files

```
├── main.tf                           # Terraform resources (null_resource automation + GWLB endpoints/routes)
├── variables.tf                      # All variables
├── outputs.tf                        # All outputs
├── provider.tf                       # AWS provider
├── versions.tf                       # Version constraints
├── ztgw-full-deploy.tfvars.example   # Template for the pure-Terraform workflow (copy to .tfvars, fill in, never commit)
├── zsec                              # Interactive wrapper (alternative workflow)
├── LICENSE                           # MIT
├── docs/
│   ├── design.md                     # Architecture decisions and API reverse-engineering notes
│   └── workflow.html                 # Visual diagram of the deployment workflow (open in a browser)
└── scripts/
    ├── deploy_ztgw.sh                # ZTGW creation + polling + activation
    └── destroy_ztgw.sh               # ZTGW deletion + activation
```
