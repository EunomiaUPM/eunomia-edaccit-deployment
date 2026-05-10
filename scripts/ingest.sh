#!/usr/bin/env bash
# ingest.sh — end-to-end ingestion pipeline
# ==========================================
# Regenerates all payload files from the source JSON-LD metadata and then
# POSTs them to the Eunomia provider API.  Run from any directory; paths
# are resolved relative to the repo root.
#
# Steps:
#   1. convert_metadata.py   — writes catalog-payloads/ (dataset + distribution)
#   2. convert_connectors.py — writes connector-payloads/ (policy + template + instance)
#   3. populate_catalog.py   — POSTs every payload to the provider API
#
# Usage:
#   ./scripts/ingest.sh
#   ./scripts/ingest.sh --provider-url http://my-host:1200
#   ./scripts/ingest.sh --dry-run
#
# All extra arguments are forwarded to populate_catalog.py, so any flag
# accepted by that script (--provider-url, --dry-run, etc.) can be passed here.
#
# Environment overrides (same defaults as the Python scripts):
#   PROVIDER_URL   — overrides --provider-url without editing the file
#
# Runtime requirements:
#   With uv (recommended): no setup needed — uv installs dependencies on the fly.
#   Without uv: activate a virtualenv with httpx installed first:
#     python3 -m venv .venv && source .venv/bin/activate
#     pip install -r services/metadata-ingestion/requirements.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
METADATA_DIR="${REPO_ROOT}/services/metadata-ingestion"

# ---------------------------------------------------------------------------
# Detect runner: prefer uv (handles inline dependencies automatically),
# fall back to plain python3 (assumes a venv with requirements installed).
# ---------------------------------------------------------------------------
if command -v uv &>/dev/null; then
    run_python() { uv run "$@"; }
    echo "[runtime] using uv"
else
    run_python() { python3 "$@"; }
    echo "[runtime] uv not found — using python3 (ensure venv is active and requirements installed)"
fi

# Honour PROVIDER_URL env var: prepend --provider-url to positional args so
# the flag is available before any user-supplied $@ arguments.
if [[ -n "${PROVIDER_URL:-}" ]]; then
    set -- --provider-url "${PROVIDER_URL}" "$@"
fi

echo "========================================"
echo "  Eunomia ingestion pipeline"
echo "========================================"

# ---------------------------------------------------------------------------
# Step 1 — Generate catalog payloads (dataset + distribution JSON files)
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 1: generating catalog payloads..."
run_python "${METADATA_DIR}/convert_metadata.py"

# ---------------------------------------------------------------------------
# Step 2 — Generate connector payloads (policy + template + instance JSON files)
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 2: generating connector payloads..."
run_python "${METADATA_DIR}/convert_connectors.py"

# ---------------------------------------------------------------------------
# Step 3 — POST everything to the provider API
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 3: populating catalog..."
run_python "${METADATA_DIR}/populate_catalog.py" "$@"
