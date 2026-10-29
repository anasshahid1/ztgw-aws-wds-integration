#!/usr/bin/env bash
#
# deploy_ztgw.sh — Terraform external data source helper for AWS ZTGW
#
# Authenticates to Zscaler OneAPI, deploys an AWS ZTGW via the REST API,
# polls until healthy, and returns JSON to Terraform.
#
# Input (via stdin JSON from Terraform external data source):
#   client_id, client_secret, vanity_domain, cloud,
#   gateway_name, aws_region, aws_region_code, availability_zone_ids,
#   location_name, allowed_accounts, account_groups, additional_aws_accounts
#
# Output (JSON to stdout for Terraform):
#   gateway_id, gateway_name, region, health_status,
#   endpoint_service_name, endpoints_count
#

set -eo pipefail

INPUT=$(cat)

CLIENT_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['client_id'])")
CLIENT_SECRET=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['client_secret'])")
VANITY_DOMAIN=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['vanity_domain'])")
CLOUD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['cloud'])")
INPUT_LOGIN_DOMAIN=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('login_domain',''))")
GATEWAY_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['gateway_name'])")
AWS_REGION=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['aws_region'])")
AWS_REGION_CODE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['aws_region_code'])")
AZ_IDS=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['availability_zone_ids'])")
LOCATION_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['location_name'])")
ALLOWED_ACCOUNTS=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('allowed_accounts','[]'))")
ACCOUNT_GROUPS=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('account_groups','[]'))")
ADDITIONAL_AWS_ACCOUNTS=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('additional_aws_accounts','[]'))")

# -----------------------------------------------------------------------
# Auto-discover availability zone IDs if not provided
# -----------------------------------------------------------------------
if [ "$AZ_IDS" = "[]" ] || [ -z "$AZ_IDS" ]; then
    echo "Auto-discovering AZ IDs for region ${AWS_REGION}..." >&2
    AZ_IDS=$(aws ec2 describe-availability-zones --region "$AWS_REGION" \
        --query "AvailabilityZones[*].ZoneId" --output json 2>/dev/null || echo "[]")
    if [ "$AZ_IDS" = "[]" ] || [ -z "$AZ_IDS" ]; then
        echo "{\"error\": \"Could not discover AZ IDs. Install AWS CLI or set availability_zone_ids variable.\"}" >&2
        exit 1
    fi
    echo "Discovered AZ IDs: $AZ_IDS" >&2
fi

# shellcheck source=./zscaler_api.sh
source "$(dirname "${BASH_SOURCE[0]}")/zscaler_api.sh"

zs_login_domain "$CLOUD" "$INPUT_LOGIN_DOMAIN"

force_activation() {
    echo "Triggering force activation via OneAPI..." >&2
    case "${CLOUD}" in
        zscaler)      ACTIVATION_BASE="https://api.zsapi.net" ;;
        zscalerbeta)  ACTIVATION_BASE="https://api.beta.zsapi.net" ;;
        zscalerone)   ACTIVATION_BASE="https://api.one.zsapi.net" ;;
        zscalertwo)   ACTIVATION_BASE="https://api.two.zsapi.net" ;;
        zscalerthree) ACTIVATION_BASE="https://api.three.zsapi.net" ;;
        *) echo "Warning: unknown cloud '${CLOUD}', skipping force activation" >&2; return ;;
    esac

    local ACTIVATE_URL="${ACTIVATION_BASE}/ztw/api/v1/ecAdminActivateStatus/forcedActivate"
    local ACTIVATE_RESPONSE
    ACTIVATE_RESPONSE=$(curl -sk --connect-timeout 10 --max-time 60 -X PUT "$ACTIVATE_URL" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{}' 2>/dev/null || true)

    echo "Force activation response: $ACTIVATE_RESPONSE" >&2
}

zs_authenticate "$CLIENT_ID" "$CLIENT_SECRET" "$VANITY_DOMAIN" "$CLOUD" "$LOGIN_DOMAIN"

echo "Checking for existing AWS ZTGW '${GATEWAY_NAME}'..." >&2
EXISTING=$(curl -sk --connect-timeout 10 --max-time 30 "$BASE_URL/ztGateway?platform=AWS" -H "$AUTH_HEADER" 2>/dev/null || true)
EXISTING_ID=$(echo "$EXISTING" | python3 -c "
import sys, json
data = json.load(sys.stdin)
gateways = data if isinstance(data, list) else data.get('list', data.get('gateways', []))
for gw in gateways:
    if gw.get('name') == '${GATEWAY_NAME}':
        print(gw['id'])
        break
" 2>/dev/null || true)

if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "" ]; then
    GATEWAY_ID="$EXISTING_ID"
    echo "Found existing AWS ZTGW '${GATEWAY_NAME}' (ID: ${GATEWAY_ID}). Checking health..." >&2

    GW_RESPONSE=$(curl -sk --connect-timeout 10 --max-time 30 "$BASE_URL/ztGateway/$GATEWAY_ID" -H "$AUTH_HEADER" 2>/dev/null || true)
    HEALTH_RAW=$(echo "$GW_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('healthStatus','UNKNOWN'))" 2>/dev/null || echo "PARSE_ERROR")
    HEALTH=$(echo "$HEALTH_RAW" | tr '[:lower:]' '[:upper:]')

    if [ "$HEALTH" = "HEALTHY" ]; then
        echo "AWS ZTGW already HEALTHY — returning immediately" >&2

        # Trigger force activation
        force_activation

        echo "$GW_RESPONSE" | python3 -c "
import sys, json
gw = json.load(sys.stdin)
print(json.dumps({
    'gateway_id': str(gw.get('id', '')),
    'gateway_name': gw.get('name', ''),
    'region': gw.get('region', ''),
    'health_status': gw.get('healthStatus', 'UNKNOWN'),
    'endpoint_service_name': gw.get('endpointServiceName', ''),
    'endpoints_count': str(gw.get('endpointsCount', '0'))
}))
"
        exit 0
    fi

    MAX_WAIT=600
    if [ "$HEALTH" = "INIT" ]; then
        echo "AWS ZTGW exists but still in INIT state. Polling for up to 10 minutes..." >&2
    else
        echo "AWS ZTGW exists but UNHEALTHY ($HEALTH_RAW). Polling for up to 10 minutes..." >&2
    fi
    IS_NEW=false
else
    # -----------------------------------------------------------------------
    # Build create payload
    # -----------------------------------------------------------------------
    echo "Creating AWS ZTGW '${GATEWAY_NAME}' in ${AWS_REGION}..." >&2

    echo "Fetching location template..." >&2
    TEMPLATES=$(curl -sk --connect-timeout 10 --max-time 30 "$BASE_URL/locationTemplate" -H "$AUTH_HEADER" 2>/dev/null || true)
    TEMPLATE_ID=$(echo "$TEMPLATES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
templates = data if isinstance(data, list) else data.get('list', data.get('templates', []))
for t in templates:
    print(t['id'])
    break
" 2>/dev/null)

    if [ -z "$TEMPLATE_ID" ]; then
        echo '{"error": "Could not retrieve location template"}' >&2
        exit 1
    fi

    CREATE_PAYLOAD=$(python3 -c "
import json

az_ids = ${AZ_IDS}
allowed_ids = ${ALLOWED_ACCOUNTS}
group_ids = ${ACCOUNT_GROUPS}
additional_aws = ${ADDITIONAL_AWS_ACCOUNTS}
template_id = ${TEMPLATE_ID}

payload = {
    'name': '${GATEWAY_NAME}',
    'platform': 'AWS',
    'region': '${AWS_REGION}',
    'awsRegion': '${AWS_REGION_CODE}',
    'availabilityZoneIds': az_ids,
    'provData': {
        'locationName': '${LOCATION_NAME}',
        'locationTemplate': {'id': template_id},
    }
}
if allowed_ids:
    payload['provData']['allowedAccounts'] = [{'id': i} for i in allowed_ids]
if group_ids:
    payload['provData']['accountGroups'] = [{'id': i} for i in group_ids]
if additional_aws:
    payload['provData']['additionalAwsAccounts'] = additional_aws
print(json.dumps(payload))
")

    CREATE_RESPONSE=$(curl -sk --connect-timeout 10 --max-time 60 -X POST "$BASE_URL/ztGateway" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$CREATE_PAYLOAD" 2>/dev/null || true)

    GATEWAY_ID=$(echo "$CREATE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

    if [ -z "$GATEWAY_ID" ]; then
        echo "$CREATE_RESPONSE" >&2
        exit 1
    fi
    echo "AWS ZTGW created (ID: ${GATEWAY_ID}). Waiting for HEALTHY status (up to 10 minutes)..." >&2
    MAX_WAIT=600
    IS_NEW=true
fi

# -----------------------------------------------------------------------
# Poll for health status
# -----------------------------------------------------------------------
INTERVAL=15
START_TIME=$(date +%s)

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))

    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "Timeout: AWS ZTGW $GATEWAY_ID did not reach HEALTHY within ${MAX_WAIT}s" >&2
        break
    fi

    zs_refresh_token_if_needed

    GW_RESPONSE=$(curl -sk --connect-timeout 10 --max-time 30 "$BASE_URL/ztGateway/$GATEWAY_ID" -H "$AUTH_HEADER" 2>/dev/null || true)

    HEALTH_RAW=$(echo "$GW_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('healthStatus','UNKNOWN'))" 2>/dev/null || echo "PARSE_ERROR")
    HEALTH=$(echo "$HEALTH_RAW" | tr '[:lower:]' '[:upper:]')

    echo "Poll: AWS ZTGW $GATEWAY_ID health=$HEALTH_RAW elapsed=${ELAPSED}s" >&2

    if [ "$HEALTH" = "HEALTHY" ]; then
        echo "AWS ZTGW $GATEWAY_ID is HEALTHY" >&2
        break
    fi

    if [ "$HEALTH" = "PARSE_ERROR" ]; then
        echo "Warning: could not parse health response, refreshing token..." >&2
        zs_authenticate "$CLIENT_ID" "$CLIENT_SECRET" "$VANITY_DOMAIN" "$CLOUD" "$LOGIN_DOMAIN"
    fi

    sleep $INTERVAL
done

if [ "$HEALTH" != "HEALTHY" ]; then
    echo "{\"error\": \"AWS ZTGW $GATEWAY_ID did not reach HEALTHY status within ${MAX_WAIT}s (current: $HEALTH_RAW). Re-run terraform apply after the gateway is healthy.\"}" >&2
    exit 1
fi

# -----------------------------------------------------------------------
# Trigger force activation
# -----------------------------------------------------------------------
force_activation

# -----------------------------------------------------------------------
# Extract outputs
# -----------------------------------------------------------------------
RESULT=$(echo "$GW_RESPONSE" | python3 -c "
import sys, json
gw = json.load(sys.stdin)
print(json.dumps({
    'gateway_id': str(gw.get('id', '')),
    'gateway_name': gw.get('name', ''),
    'region': gw.get('region', ''),
    'health_status': gw.get('healthStatus', 'UNKNOWN'),
    'endpoint_service_name': gw.get('endpointServiceName', ''),
    'endpoints_count': str(gw.get('endpointsCount', '0'))
}))
")

echo "$RESULT"
