#!/usr/bin/env bash
# arcgis-token.sh — fetch an ArcGIS token and print it to stdout
# ==============================================================
# Writes ONLY the token to stdout; all progress messages go to stderr, so the
# output can be captured directly with command substitution:
#
#   export API_VALUE=$(./scripts/arcgis-token.sh)
#   docker compose -f deployment/mini/docker-compose.mini.provider.yaml up
#
# Credentials are read from the repo-root .env. Any variable already
# exported in the shell takes precedence over the file.
#
# Usage:
#   ./scripts/arcgis-token.sh
#   ARCGIS_TOKEN_EXPIRY=1440 ./scripts/arcgis-token.sh
#   ARCGIS_USERNAME=other ARCGIS_PASSWORD=secret ./scripts/arcgis-token.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_arcgis_env

if [[ -z "${ARCGIS_USERNAME:-}" || -z "${ARCGIS_PASSWORD:-}" ]]; then
    log_error "ARCGIS_USERNAME and ARCGIS_PASSWORD must be set (via env or the repo-root .env)"
fi

CURL_OPTS=(-s)
[[ "${ARCGIS_VERIFY_SSL}" == "false" ]] && CURL_OPTS+=(-k)

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

# Report the lifetime the portal actually granted, not the one requested:
# it silently clamps expiration to its own maximum.
GRANTED=""
if command -v jq &>/dev/null; then
    GRANTED=$(echo "${TOKEN_RESPONSE}" | jq -r '
        if .expires then ((.expires / 1000 - now) / 60 | floor | tostring) else empty end')
fi

if [[ -n "${GRANTED}" && "${GRANTED}" != "${ARCGIS_TOKEN_EXPIRY}" ]]; then
    log_success "Token obtained (valid ${GRANTED} min - the portal capped the ${ARCGIS_TOKEN_EXPIRY} min requested)"
else
    log_success "Token obtained (valid ${GRANTED:-${ARCGIS_TOKEN_EXPIRY}} min)"
fi

# The token — and nothing else — on stdout
printf '%s\n' "${TOKEN}"
