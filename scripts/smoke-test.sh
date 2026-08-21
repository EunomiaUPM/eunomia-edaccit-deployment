#!/usr/bin/env bash
# smoke-test.sh — end-to-end ArcGIS connectivity check
# =====================================================
# 1. Generates a token via the ESRILab portal.
# 2. Queries the FeatureServer to confirm the layer is accessible.
#
# Credentials are loaded from the repo-root .env.
# Any variable already exported in the shell takes precedence over the file.
#
# Usage:
#   ./scripts/smoke-test.sh
#   ARCGIS_USERNAME=other ARCGIS_PASSWORD=secret ./scripts/smoke-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Needed here for ARCGIS_SERVER_URL / ARCGIS_VERIFY_SSL in Step 2;
# arcgis-token.sh loads it again on its own for the credentials.
load_arcgis_env

CURL_OPTS=(-s)
[[ "${ARCGIS_VERIFY_SSL}" == "false" ]] && CURL_OPTS+=(-k)

LAYER_PATH="/rest/services/Hosted/Fuente1_Infraestructuraferroviaria/FeatureServer/0"

# ---------------------------------------------------------------------------
# Step 1 — Generate token
# ---------------------------------------------------------------------------
log_step "Step 1 · Generating token"

TOKEN="$("${SCRIPT_DIR}/arcgis-token.sh")"
log_info "Token : ${TOKEN}"

# ---------------------------------------------------------------------------
# Step 2 — Query FeatureServer
# ---------------------------------------------------------------------------
log_step "Step 2 · Querying FeatureServer"
log_info "Layer: ${ARCGIS_SERVER_URL}${LAYER_PATH}"

QUERY_RESPONSE=$(curl "${CURL_OPTS[@]}" \
    "${ARCGIS_SERVER_URL}${LAYER_PATH}/query?where=1%3D1&outFields=*&f=geojson&resultRecordCount=3&token=${TOKEN}")

if command -v jq &>/dev/null; then
    FEATURE_COUNT=$(echo "${QUERY_RESPONSE}" | jq '.features | length')
    QUERY_ERROR=$(echo "${QUERY_RESPONSE}" | jq -r '.error.message // empty')
else
    FEATURE_COUNT=$(echo "${QUERY_RESPONSE}" | grep -o '"type":"Feature"' | wc -l | tr -d ' ')
    QUERY_ERROR=""
fi

if [[ -n "${QUERY_ERROR:-}" ]]; then
    log_error "Layer query failed: ${QUERY_ERROR}"
fi

if [[ "${FEATURE_COUNT:-0}" -gt 0 ]]; then
    log_success "Received ${FEATURE_COUNT} feature(s) — layer is accessible"
else
    log_error "Query returned 0 features. Response: ${QUERY_RESPONSE}"
fi

log_step "Smoke test passed"
