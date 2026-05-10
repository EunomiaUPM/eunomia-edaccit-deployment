#!/bin/sh
set -e

# Extract --provider-url from args (default matches docker-compose command)
PROVIDER_URL="http://provider:1200"
prev=""
for arg; do
    case "$prev" in --provider-url) PROVIDER_URL="$arg" ;; esac
    prev="$arg"
done

HEALTH_URL="${PROVIDER_URL}/api/v1/catalog-agent/catalogs/main"
MAX_RETRIES=24   # 24 × 10 s = 4 min ceiling
INTERVAL=10

printf '==> Waiting for provider at %s\n' "$PROVIDER_URL"
i=0
until python -c "import httpx; httpx.get('${HEALTH_URL}', timeout=5).raise_for_status()" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge "$MAX_RETRIES" ]; then
        printf 'ERROR: provider not ready after %ds — giving up\n' "$((MAX_RETRIES * INTERVAL))" >&2
        exit 1
    fi
    printf '  [%d/%d] not ready yet, retrying in %ds...\n' "$i" "$MAX_RETRIES" "$INTERVAL"
    sleep "$INTERVAL"
done

printf '==> Provider is ready — starting ingestion\n'
exec python populate_catalog.py "$@"
