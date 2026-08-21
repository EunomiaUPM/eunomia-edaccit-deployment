#!/usr/bin/env bash
# ingest-arcgis-token.sh — fetch an ArcGIS token and run the full ingestion pipeline
# ====================================================================================
# 1. Fetches a token via scripts/arcgis-token.sh (credentials come from
#    the repo-root .env; any variable already exported in the shell
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
#
# Note: datasets, distributions and policies are created (not upserted), so
# re-running this against an already populated provider duplicates the catalog.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# The token is baked into every connector instance at POST time and nothing
# refreshes it afterwards, so ingestion asks for a long-lived one (1 year).
# The portal may silently clamp this to its own maximum.
export ARCGIS_TOKEN_EXPIRY="${ARCGIS_TOKEN_EXPIRY:-525600}"

# ---------------------------------------------------------------------------
# Step 1 — Fetch ArcGIS token
# ---------------------------------------------------------------------------
log_step "Step 1 · Fetching ArcGIS token"

TOKEN="$("${SCRIPT_DIR}/arcgis-token.sh")"

# ---------------------------------------------------------------------------
# Step 2 — Run ingestion pipeline with the token as API_VALUE
# ---------------------------------------------------------------------------
log_step "Step 2 · Running ingestion pipeline"

exec "${SCRIPT_DIR}/ingest.sh" --api-value "${TOKEN}" "$@"
