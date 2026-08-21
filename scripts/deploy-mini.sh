#!/usr/bin/env bash
# deploy-mini.sh — bring up the whole mini deployment and onboard it
# ==================================================================
# Encodes the deployment sequence end to end:
#
#   1. git pull                       (you, beforehand)
#   2. export API_VALUE=$(./scripts/arcgis-token.sh)
#   3. docker compose up  authority → provider → consumer → map-viewer
#   4. ./scripts/mini-onboarding.sh
#
# Steps 2-4 are what this script does. Everything it runs is idempotent, so
# re-running it after a `git pull` is safe: the catalog is not duplicated and
# participants already registered with the authority are left alone.
#
# Usage:
#   ./scripts/deploy-mini.sh
#   API_VALUE=<token> ./scripts/deploy-mini.sh   # reuse a token you already have
#   ./scripts/deploy-mini.sh --no-onboarding     # just bring the stacks up
#   ./scripts/deploy-mini.sh --no-map-viewer     # skip the map viewer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MINI_DIR="${REPO_ROOT}/deployment/mini"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

RUN_ONBOARDING=true
WITH_MAP_VIEWER=true
for arg in "$@"; do
    case "${arg}" in
        --no-onboarding) RUN_ONBOARDING=false ;;
        --no-map-viewer) WITH_MAP_VIEWER=false ;;
        *) log_error "Unknown argument: ${arg}" ;;
    esac
done

# ---------------------------------------------------------------------------
# Guard: a natively built agent on the same port silently wins over Docker.
# Docker publishes on IPv6, those binaries bind IPv4, so 127.0.0.1:<port>
# reaches the stray process while the container looks perfectly healthy.
# ---------------------------------------------------------------------------
for port in 1100 1200 1500 8000; do
    if lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | grep -qvE '^COMMAND|com\.docke'; then
        log_error "Port ${port} is taken by a non-Docker process. Stop it before deploying:
$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN | grep -vE '^COMMAND|com\.docke')"
    fi
done

# ---------------------------------------------------------------------------
# Step 1 — ArcGIS token
# ---------------------------------------------------------------------------
if [[ -n "${API_VALUE:-}" ]]; then
    log_step "Step 1 · Using API_VALUE from the environment"
else
    log_step "Step 1 · Fetching ArcGIS token"
    # Baked into every connector instance and never refreshed, so ask for the
    # longest lifetime the portal will grant.
    export ARCGIS_TOKEN_EXPIRY="${ARCGIS_TOKEN_EXPIRY:-525600}"
    API_VALUE="$("${SCRIPT_DIR}/arcgis-token.sh")"
    export API_VALUE
fi

# ---------------------------------------------------------------------------
# Step 2 — Compose stacks
# ---------------------------------------------------------------------------
log_step "Step 2 · Starting authority"
docker compose -f "${MINI_DIR}/docker-compose.mini.heimdall.yaml" up -d --wait

log_step "Step 2 · Starting provider (+ metadata ingestion)"
docker compose -f "${MINI_DIR}/docker-compose.mini.provider.yaml" up -d

log_step "Step 2 · Starting consumer"
docker compose -f "${MINI_DIR}/docker-compose.mini.consumer.yaml" up -d

if [[ "${WITH_MAP_VIEWER}" == true ]]; then
    log_step "Step 2 · Starting map viewer"
    # --build because the SPA is compiled into the image: Vite bakes the
    # VITE_* vars at build time, so a plain `up` would serve the stale bundle
    # after a pull. Docker's layer cache makes this a no-op when nothing moved.
    docker compose -f "${MINI_DIR}/docker-compose.mini.map-viewer.yaml" up -d --build
fi

# ---------------------------------------------------------------------------
# Step 3 — Wait for the agents
# ---------------------------------------------------------------------------
# The agents expose no healthcheck, so compose reports them up the moment the
# process starts — several seconds before the router answers.
wait_for() {
    local name=$1 url=$2 i=0
    until curl -sf -o /dev/null --max-time 5 "${url}"; do
        i=$((i + 1))
        if [ "${i}" -ge 60 ]; then
            log_error "${name} did not become ready (${url})"
        fi
        sleep 2
    done
    log_success "${name} is ready"
}

log_step "Step 3 · Waiting for the agents"
wait_for "Authority" "${AUTHORITY_URL}/readiness"
wait_for "Provider"  "${PROVIDER_URL}/api/v1/catalog-agent/catalogs/main"
wait_for "Consumer"  "${CONSUMER_URL}/api/v1/catalog-agent/catalogs/main"
[[ "${WITH_MAP_VIEWER}" == true ]] && wait_for "Map viewer" "${MAP_VIEWER_URL}/api/health"

# ---------------------------------------------------------------------------
# Step 4 — Onboarding
# ---------------------------------------------------------------------------
if [[ "${RUN_ONBOARDING}" == true ]]; then
    bash "${SCRIPT_DIR}/mini-onboarding.sh"
else
    log_info "Skipping onboarding (--no-onboarding)"
fi

echo
SUMMARY="Mini deployment ready:
  Authority  : ${AUTHORITY_URL}/admin/home
  Provider   : ${PROVIDER_URL}/admin/login
  Consumer   : ${CONSUMER_URL}/admin/login"
[[ "${WITH_MAP_VIEWER}" == true ]] && SUMMARY="${SUMMARY}
  Map viewer : ${MAP_VIEWER_URL}"
log_success "${SUMMARY}"
