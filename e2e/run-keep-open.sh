#!/usr/bin/env bash
# run-keep-open.sh — stops at STARTED, leaving the dataplane proxy usable.
# Docker is the only requirement; extra arguments are forwarded to the test.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec docker compose -f docker-compose.e2e.yaml run --rm --build e2e --keep-open "$@"
