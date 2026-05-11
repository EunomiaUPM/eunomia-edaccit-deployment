#!/usr/bin/env bash
# ingest-arcgis-token.sh — fetch an ArcGIS token and run the full ingestion pipeline
# ====================================================================================
# 1. Fetches a token from the ESRILab portal using the credentials in
#    services/map-viewer/.env (any variable already exported in the shell
#    takes precedence over the file).
# 2. Runs the full ingest pipeline (convert_metadata → convert_connectors →
#    populate_catalog) passing the token as --api-value so every connector
#    instance is registered with the real API secret.
#
# Any extra CLI arguments are forwarded to populate_catalog.py, so flags such
# as --provider-url or --dry-run work as usual:
#
# Usage:
#   ./scripts/ingest-arcgis-token.sh
#   ./scripts/ingest-arcgis-token.sh --dry-run
#   ./scripts/ingest-arcgis-token.sh --provider-url http://my-host:1200
#   ARCGIS_USERNAME=other ARCGIS_PASSWORD=secret ./scripts/ingest-arcgis-token.sh

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
        if [[ -z "${!key+x}" ]]; then
            export "${key}=${value}"
        fi
    done < "${ENV_FILE}"
fi

ARCGIS_PORTAL_URL="${ARCGIS_PORTAL_URL:-https://edaccit.esrilab.es/portal}"
ARCGIS_TOKEN_EXPIRY="${ARCGIS_TOKEN_EXPIRY:-120}"
ARCGIS_REFERER="${ARCGIS_REFERER:-https://edaccit.esrilab.es}"
ARCGIS_VERIFY_SSL="${ARCGIS_VERIFY_SSL:-true}"

if [[ -z "${ARCGIS_USERNAME:-}" || -z "${ARCGIS_PASSWORD:-}" ]]; then
    log_error "ARCGIS_USERNAME and ARCGIS_PASSWORD must be set (via env or services/map-viewer/.env)"
fi

CURL_OPTS=(-s)
[[ "${ARCGIS_VERIFY_SSL}" == "false" ]] && CURL_OPTS+=(-k)

# ---------------------------------------------------------------------------
# Step 1 — Fetch ArcGIS token
# ---------------------------------------------------------------------------
log_step "Step 1 · Fetching ArcGIS token"
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

# ---------------------------------------------------------------------------
# Step 2 — Run ingestion pipeline with the token as API_VALUE
# ---------------------------------------------------------------------------
log_step "Step 2 · Running ingestion pipeline"

exec "${SCRIPT_DIR}/ingest.sh" --api-value "${TOKEN}" "$@"
