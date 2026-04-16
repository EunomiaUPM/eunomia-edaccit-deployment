#!/bin/bash

# ----------------------------
# Parameters (with defaults)
# ----------------------------

LOCAL_AUTHORITY="${1:-http://127.0.0.1:1500}"
LOCAL_CONSUMER="${2:-http://127.0.0.1:1100}"
LOCAL_PROVIDER="${3:-http://127.0.0.1:1200}"
DOCKER_AUTHORITY="${1:-http://127.0.0.1:1500}"
DOCKER_CONSUMER="${2:-http://127.0.0.1:1100}"
DOCKER_PROVIDER="${3:-http://127.0.0.1:1200}"


# ----------------------------
# Logging helpers
# ----------------------------

log_step() {
    echo ""
    echo -e "\033[0;36m$1\033[0m"
}

log_success() {
    echo -e "\033[0;32m$1\033[0m"
}

log_error() {
    echo -e "\033[0;31m$1\033[0m"
}

log_info() {
    echo -e "\033[0;33m$1\033[0m"
}

# ----------------------------
# HTTP helper (fail-fast)
# ----------------------------

invoke_curl_json() {
    local METHOD="${1:-GET}"
    local URL="$2"
    local BODY="$3"

    if [ -n "$BODY" ]; then
        RESPONSE=$(curl -s -w "\n%{http_code}" -X "$METHOD" "$URL" \
            -H "Content-Type: application/json" \
            -d "$BODY")
    else
        RESPONSE=$(curl -s -w "\n%{http_code}" -X "$METHOD" "$URL" \
            -H "Content-Type: application/json")
    fi

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY_RESPONSE=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        log_success "SUCCESS: $METHOD $URL -> $HTTP_CODE"
    else
        log_error "ERROR: $METHOD $URL -> $HTTP_CODE"
        log_error "$BODY_RESPONSE"
        exit 1
    fi

    echo "$BODY_RESPONSE"
}

echo ""
echo -e "\033[0;36m======================================\033[0m"
echo -e "\033[0;36m        GAIA LOCAL FLOW\033[0m"
echo -e "\033[0;36m======================================\033[0m"

# ----------------------------
# STEP 1 - Link wallets
# ----------------------------

log_step "STEP 1 - Linking wallets"

invoke_curl_json "POST" "$LOCAL_CONSUMER/api/v1/wallet/link" > /dev/null
invoke_curl_json "POST" "$LOCAL_PROVIDER/api/v1/wallet/link" > /dev/null
invoke_curl_json "POST" "$LOCAL_AUTHORITY/api/v1/wallet/link" > /dev/null

# ----------------------------
# STEP 2 - Retrieve DIDs
# ----------------------------

log_step "STEP 2 - Retrieving DIDs"

CONSUMER_DID=$(invoke_curl_json "GET" "$LOCAL_CONSUMER/.well-known/did.json" | jq -r '.id')
log_success "Consumer DID: $CONSUMER_DID"

PROVIDER_DID=$(invoke_curl_json "GET" "$LOCAL_PROVIDER/.well-known/did.json" | jq -r '.id')
log_success "Provider DID: $PROVIDER_DID"

AUTHORITY_DID=$(invoke_curl_json "GET" "$LOCAL_AUTHORITY/.well-known/did.json" | jq -r '.id')
log_success "Authority DID: $AUTHORITY_DID"

# ----------------------------
# STEP 3 - Request Legal VC
# ----------------------------

log_step "STEP 3 - Requesting Legal VC"

LEGAL_BODY=$(jq -n \
    --arg url "$DOCKER_AUTHORITY/api/v1/gate/access" \
    --arg id "$AUTHORITY_DID" \
    '{url: $url, id: $id, slug: "authority", vc_type: "gx_VatId_jwt_vc_json", method: "cert", auto: true}')

invoke_curl_json "POST" "$LOCAL_CONSUMER/api/v1/vc-request/beg" "$LEGAL_BODY" > /dev/null

# ----------------------------
# STEP 4 - Authority gets requests
# ----------------------------

log_step "STEP 4 - Fetching requests"

ALL_REQUESTS=$(invoke_curl_json "GET" "$LOCAL_AUTHORITY/api/v1/approver/all")
PETITION_ID=$(echo "$ALL_REQUESTS" | jq -r '.[-1].id')
log_info "Petition ID: $PETITION_ID"

# ----------------------------
# STEP 5 - Approve request
# ----------------------------

log_step "STEP 5 - Approving request"

invoke_curl_json "POST" "$LOCAL_AUTHORITY/api/v1/approver/$PETITION_ID" \
    '{"approve": true}' > /dev/null

log_success "Request approved"

# ----------------------------
# STEP 6 - Generate Gaia VCs
# ----------------------------

log_step "STEP 6 - Generating Gaia VCs"

invoke_curl_json "POST" "$LOCAL_CONSUMER/api/v1/gaia/credential/generate" > /dev/null

# ----------------------------
# STEP 7 - Request Label VC (OIDC4VP)
# ----------------------------

log_step "STEP 7 - Request Label VC"

LABEL_BODY=$(jq -n \
    --arg url "$DOCKER_AUTHORITY/api/v1/gate/access" \
    --arg id "$AUTHORITY_DID" \
    '{url: $url, id: $id, slug: "authority", vc_type: "gx_LabelCredential_jwt_vc_json", method: "oidc4vp", auto: true}')

invoke_curl_json "POST" "$LOCAL_CONSUMER/api/v1/vc-request/beg" "$LABEL_BODY" > /dev/null

# ----------------------------
# STEP 8 - Talk Provider
# ----------------------------

log_step "STEP 8 - Talking to Provider"

PROVIDER_BODY=$(jq -n \
    --arg url "$DOCKER_PROVIDER/api/v1/gate/access" \
    --arg id "$PROVIDER_DID" \
    '{url: $url, id: $id, slug: "provider", actions: ["talk"], auto: true}')

invoke_curl_json "POST" "$LOCAL_CONSUMER/api/v1/onboard/provider" "$PROVIDER_BODY" > /dev/null

# ----------------------------
# DONE
# ----------------------------

echo ""
echo -e "\033[0;32m======================================\033[0m"
echo -e "\033[0;32m     GAIA FLOW COMPLETED\033[0m"
echo -e "\033[0;32m======================================\033[0m"
echo ""