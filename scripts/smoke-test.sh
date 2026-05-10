#!/usr/bin/env bash
# smoke-test.sh — end-to-end ArcGIS connectivity check
# =====================================================
# 1. Generates a token via the ESRILab portal.
# 2. Queries the FeatureServer to confirm the layer is accessible.
#
# Credentials are loaded from services/map-viewer/.env.
# Any variable already exported in the shell takes precedence over the file.
#
# Usage:
#   ./scripts/smoke-test.sh
#   ARCGIS_USERNAME=other ARCGIS_PASSWORD=secret ./scripts/smoke-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Load credentials — env vars already exported take precedence over .env
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/services/map-viewer/.env"
if [[ -f "${ENV_FILE}" ]]; then
    while IFS='=' read -r key value; do
        [[ "${key}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// /}" ]] && continue
        key="${key// /}"
        # Only set if the variable is not already in the environment
        if [[ -z "${!key+x}" ]]; then
            export "${key}=${value}"
        fi
    done < "${ENV_FILE}"
fi

ARCGIS_PORTAL_URL="${ARCGIS_PORTAL_URL:-https://edaccit.esrilab.es/portal}"
ARCGIS_SERVER_URL="${ARCGIS_SERVER_URL:-https://edaccit.esrilab.es/server}"
ARCGIS_TOKEN_EXPIRY="${ARCGIS_TOKEN_EXPIRY:-120}"
ARCGIS_REFERER="${ARCGIS_REFERER:-https://edaccit.esrilab.es}"
ARCGIS_VERIFY_SSL="${ARCGIS_VERIFY_SSL:-true}"

if [[ -z "${ARCGIS_USERNAME:-}" || -z "${ARCGIS_PASSWORD:-}" ]]; then
    log_error "ARCGIS_USERNAME and ARCGIS_PASSWORD must be set (via env or services/map-viewer/.env)"
fi

CURL_OPTS=(-s)
[[ "${ARCGIS_VERIFY_SSL}" == "false" ]] && CURL_OPTS+=(-k)

LAYER_PATH="/rest/services/Hosted/Fuente1_Infraestructuraferroviaria/FeatureServer/0"

# ---------------------------------------------------------------------------
# Step 1 — Generate token
# ---------------------------------------------------------------------------
log_step "Step 1 · Generating token"
log_info "Portal : ${ARCGIS_PORTAL_URL}"
log_info "User   : ${ARCGIS_USERNAME}"

TOKEN_RESPONSE=$(curl "${CURL_OPTS[@]}" -X POST \
    "${ARCGIS_PORTAL_URL}/sharing/rest/generateToken" \
    -d "f=json" \
    -d "username=${ARCGIS_USERNAME}" \
    -d "password=${ARCGIS_PASSWORD}" \
    -d "client=referer" \
    -d "referer=${ARCGIS_REFERER}" \
    -d "expiration=${ARCGIS_TOKEN_EXPIRY}")

if command -v jq &>/dev/null; then
    TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.token // empty')
else
    TOKEN=$(echo "${TOKEN_RESPONSE}" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
fi

if [[ -z "${TOKEN:-}" ]]; then
    log_error "Token generation failed. Response: ${TOKEN_RESPONSE}"
fi
log_success "Token obtained (expires in ${ARCGIS_TOKEN_EXPIRY} min)"
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
