#!/usr/bin/env bash
#
# zscaler_api.sh — shared Zscaler OneAPI auth + generic GET helper.
#
# Sourced by: zsec, scripts/deploy_ztgw.sh, scripts/destroy_ztgw.sh
#
# Previously this OAuth2/login-domain logic was copy-pasted independently
# in deploy_ztgw.sh and destroy_ztgw.sh. Extracted here to avoid a third
# duplicate when zsec also needed to authenticate directly (to query
# /publicCloudInfo and /accountGroups for the WDS account/group selection
# step, before terraform ever runs).
#
# Usage:
#   source "$(dirname "$0")/scripts/zscaler_api.sh"
#   zs_login_domain "$CLOUD" "$INPUT_LOGIN_DOMAIN"   # sets LOGIN_DOMAIN
#   zs_authenticate "$CLIENT_ID" "$CLIENT_SECRET" "$VANITY_DOMAIN" "$CLOUD" "$LOGIN_DOMAIN"
#                                                      # sets ACCESS_TOKEN, AUTH_HEADER,
#                                                      # TOKEN_TIME, BASE_URL, TOKEN_URL
#   zs_refresh_token_if_needed                        # re-auths if token older than 240s
#   zs_get "/publicCloudInfo"                          # generic authenticated GET
#

# ---------------------------------------------------------------------------
# zs_login_domain CLOUD INPUT_OVERRIDE
#   Sets global LOGIN_DOMAIN based on cloud, or uses the override if given.
# ---------------------------------------------------------------------------
zs_login_domain() {
    local cloud="$1"
    local override="$2"

    if [ "$cloud" = "zscaler" ]; then
        LOGIN_DOMAIN="zslogin.net"
    elif [ "$cloud" = "zscalerbeta" ]; then
        LOGIN_DOMAIN="zsloginbeta.net"
    elif [ "$cloud" = "zscalerthree" ]; then
        LOGIN_DOMAIN="zsloginthree.net"
    elif [ "$cloud" = "zscalerone" ]; then
        LOGIN_DOMAIN="zsloginone.net"
    elif [ "$cloud" = "zscalertwo" ]; then
        LOGIN_DOMAIN="zslogintwo.net"
    else
        LOGIN_DOMAIN="zslogin.net"
    fi

    if [ -n "$override" ]; then
        LOGIN_DOMAIN="$override"
        echo "Using custom login domain: ${LOGIN_DOMAIN}" >&2
    fi
}

# ---------------------------------------------------------------------------
# zs_authenticate CLIENT_ID CLIENT_SECRET VANITY_DOMAIN CLOUD LOGIN_DOMAIN
#   Sets globals: ACCESS_TOKEN, AUTH_HEADER, TOKEN_TIME, BASE_URL, TOKEN_URL,
#   ZS_CLIENT_ID, ZS_CLIENT_SECRET (cached for zs_refresh_token_if_needed).
#   Exits 1 with a JSON error on stderr if authentication fails.
# ---------------------------------------------------------------------------
zs_authenticate() {
    ZS_CLIENT_ID="$1"
    ZS_CLIENT_SECRET="$2"
    ZS_VANITY_DOMAIN="$3"
    ZS_CLOUD="$4"
    LOGIN_DOMAIN="$5"

    TOKEN_URL="https://${ZS_VANITY_DOMAIN}.${LOGIN_DOMAIN}/oauth2/v1/token"
    BASE_URL="https://connector.${ZS_CLOUD}.net/api/v1"

    local token_resp
    token_resp=$(curl -sk --connect-timeout 10 --max-time 30 -X POST "$TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials&client_id=${ZS_CLIENT_ID}&client_secret=${ZS_CLIENT_SECRET}" 2>/dev/null || true)

    ACCESS_TOKEN=$(echo "$token_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)

    if [ -z "$ACCESS_TOKEN" ]; then
        echo '{"error": "Authentication failed"}' >&2
        return 1
    fi

    AUTH_HEADER="Authorization: Bearer $ACCESS_TOKEN"
    TOKEN_TIME=$(date +%s)
    echo "Authenticated successfully" >&2
}

# ---------------------------------------------------------------------------
# zs_refresh_token_if_needed
#   Re-authenticates using the cached credentials if the token is older
#   than 240 seconds. Requires zs_authenticate to have been called once
#   already (uses ZS_CLIENT_ID/ZS_CLIENT_SECRET cached globals).
# ---------------------------------------------------------------------------
zs_refresh_token_if_needed() {
    local now
    now=$(date +%s)
    local age=$((now - TOKEN_TIME))
    if [ $age -ge 240 ]; then
        echo "Refreshing OAuth2 token (age: ${age}s)..." >&2
        zs_authenticate "$ZS_CLIENT_ID" "$ZS_CLIENT_SECRET" "$ZS_VANITY_DOMAIN" "$ZS_CLOUD" "$LOGIN_DOMAIN"
    fi
}

# ---------------------------------------------------------------------------
# zs_get PATH
#   Generic authenticated GET against $BASE_URL. Prints the raw JSON
#   response body to stdout. Caller handles parsing/errors.
# ---------------------------------------------------------------------------
zs_get() {
    local path="$1"
    curl -sk --connect-timeout 10 --max-time 30 "${BASE_URL}${path}" -H "$AUTH_HEADER" 2>/dev/null || true
}
