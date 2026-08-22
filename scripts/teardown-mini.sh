#!/usr/bin/env bash
# teardown-mini.sh — remove every trace of the mini deployment
# ============================================================
# The inverse of deploy-mini.sh. Leaves the machine as if the deployment had
# never run, so the next `./scripts/deploy-mini.sh` starts from nothing:
#
#   1. docker compose down on all five stacks (containers + networks + volumes)
#   2. sweep any stray edaccit-* container or network compose did not own
#   3. wipe the generated identity material under vault/
#   4. verify every port the deployment publishes is free again
#
# Step 3 is what makes this a real reset rather than a restart. The agents'
# DIDs, keys and wallet state live in vault/ through a bind mount, not in a
# Docker volume, so `docker compose down -v` leaves them behind and a redeploy
# silently reuses the old identities.
#
# Only generated files are removed there: vault/ also holds committed .example
# files the deployment needs to boot, and deleting those breaks the repo.
#
# What this does NOT touch:
#   - the repo-root .env (your ArcGIS credentials)
#   - services/metadata-ingestion/*-payloads/ (committed, not generated state)
#   - images, unless you pass --images
#
# Usage:
#   ./scripts/teardown-mini.sh                 # asks for confirmation first
#   ./scripts/teardown-mini.sh --dry-run       # show what would be removed
#   ./scripts/teardown-mini.sh --yes           # no prompt (for automation)
#   ./scripts/teardown-mini.sh --images        # also remove the built images
#   ./scripts/teardown-mini.sh --keep-identities   # keep vault/, just stop everything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MINI_DIR="${REPO_ROOT}/deployment/mini"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ASSUME_YES=false
DRY_RUN=false
REMOVE_IMAGES=false
KEEP_IDENTITIES=false

for arg in "$@"; do
    case "${arg}" in
        --yes|-y)         ASSUME_YES=true ;;
        --dry-run|-n)     DRY_RUN=true ;;
        --images)         REMOVE_IMAGES=true ;;
        --keep-identities) KEEP_IDENTITIES=true ;;
        --help|-h)        sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) log_error "Unknown argument: ${arg}" ;;
    esac
done

# The provider stack declares API_VALUE as a required variable, so compose
# cannot even parse that file without one — `down` fails just like `up`. The
# value is never used while tearing down; it only has to exist.
export API_VALUE="${API_VALUE:-teardown-placeholder}"

COMPOSE_FILES=(
    "${MINI_DIR}/docker-compose.mini.map-viewer.yaml"
    "${MINI_DIR}/docker-compose.mini.consumer.yaml"
    "${MINI_DIR}/docker-compose.mini.provider.yaml"
    "${MINI_DIR}/docker-compose.mini.heimdall.yaml"
    "${REPO_ROOT}/e2e/docker-compose.e2e.yaml"
)

# Published by the four stacks: agents, databases and caches.
PORTS=(1100 1200 1300 1400 1450 1500 6379 6380 8000)

run() {
    if [[ "${DRY_RUN}" == true ]]; then
        echo "  would run: $*" >&2
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" == false && "${ASSUME_YES}" == false ]]; then
    echo
    log_info "This removes the whole mini deployment:"
    log_info "  · every edaccit-* container, network and volume"
    log_info "  · the catalog and all negotiated agreements (they live in the databases)"
    [[ "${KEEP_IDENTITIES}" == false ]] && \
        log_info "  · the generated identities in vault/ — the agents get new DIDs"
    [[ "${REMOVE_IMAGES}" == true ]] && \
        log_info "  · the images built for map-viewer, metadata-ingestion and e2e"
    echo
    log_info "Redeploying afterwards needs an ArcGIS token, so make sure the"
    log_info "credentials in .env still work before wiping this."
    echo
    # No prompt is possible without a terminal; refuse rather than assume yes.
    if [[ ! -t 0 ]]; then
        log_error "Not running interactively. Re-run with --yes to confirm, or --dry-run to preview."
    fi
    read -r -p "Type 'yes' to continue: " reply
    [[ "${reply}" == "yes" ]] || log_error "Aborted, nothing was removed."
fi

[[ "${DRY_RUN}" == true ]] && log_info "DRY RUN — nothing will actually be removed"

# ---------------------------------------------------------------------------
# Step 1 — Compose down
# ---------------------------------------------------------------------------
log_step "Step 1 · Stopping the stacks"

DOWN_ARGS=(--volumes --remove-orphans)
[[ "${REMOVE_IMAGES}" == true ]] && DOWN_ARGS+=(--rmi local)

for file in "${COMPOSE_FILES[@]}"; do
    if [[ ! -f "${file}" ]]; then
        log_info "Skipping $(basename "${file}") — not found"
        continue
    fi
    log_info "down: $(basename "${file}")"
    # A stack that was never started makes `down` a successful no-op, so a
    # failure here is a real problem and should not be swallowed.
    run docker compose -f "${file}" down "${DOWN_ARGS[@]}"
done

# ---------------------------------------------------------------------------
# Step 2 — Sweep leftovers
# ---------------------------------------------------------------------------
# Anything started outside compose, or left behind by an interrupted run, is
# invisible to `down` but still holds its name and port.
log_step "Step 2 · Sweeping stray containers and networks"

STRAY=$(docker ps -aq --filter "name=^/edaccit-" 2>/dev/null || true)
if [[ -n "${STRAY}" ]]; then
    log_info "Removing $(echo "${STRAY}" | wc -l | tr -d ' ') leftover container(s)"
    # shellcheck disable=SC2086
    run docker rm -f ${STRAY}
else
    log_success "No stray containers"
fi

STRAY_NET=$(docker network ls -q --filter "name=edaccit" 2>/dev/null || true)
if [[ -n "${STRAY_NET}" ]]; then
    log_info "Removing $(echo "${STRAY_NET}" | wc -l | tr -d ' ') leftover network(s)"
    # shellcheck disable=SC2086
    run docker network rm ${STRAY_NET} >/dev/null 2>&1 || true
else
    log_success "No stray networks"
fi

# The stacks declare no named volumes today (the databases write to the
# container layer), but --volumes above plus this check keeps the teardown
# honest if one is ever added.
STRAY_VOL=$(docker volume ls -q --filter "name=edaccit" 2>/dev/null || true)
if [[ -n "${STRAY_VOL}" ]]; then
    log_info "Removing leftover volume(s)"
    # shellcheck disable=SC2086
    run docker volume rm ${STRAY_VOL} >/dev/null 2>&1 || true
else
    log_success "No stray volumes"
fi

# ---------------------------------------------------------------------------
# Step 3 — Generated identity material
# ---------------------------------------------------------------------------
log_step "Step 3 · Wiping generated state in vault/"

if [[ "${KEEP_IDENTITIES}" == true ]]; then
    log_info "Keeping vault/ (--keep-identities) — the agents will reuse their DIDs"
elif [[ ! -d "${REPO_ROOT}/vault" ]]; then
    log_info "No vault/ directory, nothing to wipe"
elif git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # git knows exactly which files are committed and which the deployment
    # generated, so it draws the line for us. -x includes ignored files, which
    # is where the generated keys live; tracked files are never touched.
    # LC_ALL=C because this parses git's output, which is translated: the
    # prefix is "Would remove" only in an English locale.
    PENDING=$(LC_ALL=C git -C "${REPO_ROOT}" clean -ndx -- vault/ | sed 's/^Would remove /  /')
    if [[ -z "${PENDING}" ]]; then
        log_success "vault/ is already clean"
    else
        echo "${PENDING}" >&2
        run git -C "${REPO_ROOT}" clean -fdx -- vault/ >/dev/null
        log_success "Generated identity material removed"
    fi
else
    # Not a git checkout (a copied directory on the production box, say), so
    # fall back to the filenames the setup jobs are known to generate.
    log_info "Not a git checkout — removing the known generated files"
    for participant in consumer provider heimdall; do
        for name in cert.json.example private_key.json.example public_key.json.example; do
            target="${REPO_ROOT}/vault/${participant}/secrets/${name}"
            [[ -f "${target}" ]] && run rm -f "${target}"
        done
        data_dir="${REPO_ROOT}/vault/${participant}/data"
        if [[ -d "${data_dir}" ]]; then
            # .gitkeep is committed and keeps the directory present.
            run find "${data_dir}" -mindepth 1 ! -name '.gitkeep' -delete
        fi
    done
    log_success "Generated identity material removed"
fi

# ---------------------------------------------------------------------------
# Step 4 — Ports
# ---------------------------------------------------------------------------
log_step "Step 4 · Checking the ports are free"

if [[ "${DRY_RUN}" == true ]]; then
    log_info "Skipped in dry-run mode"
elif ! command -v lsof >/dev/null 2>&1; then
    log_info "lsof not available — skipping the port check"
else
    BUSY=false
    for port in "${PORTS[@]}"; do
        HOLDER=$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | grep -v '^COMMAND' || true)
        if [[ -n "${HOLDER}" ]]; then
            BUSY=true
            log_info "Port ${port} is still in use:"
            echo "${HOLDER}" >&2
        fi
    done
    if [[ "${BUSY}" == true ]]; then
        # deploy-mini.sh refuses to start when a non-Docker process squats on
        # one of these, so surface it now rather than at the next deploy.
        log_error "Some ports are still held. Stop the process above before redeploying."
    fi
    log_success "All ${#PORTS[@]} ports are free"
fi

# ---------------------------------------------------------------------------
echo
if [[ "${DRY_RUN}" == true ]]; then
    log_success "Dry run complete — nothing was removed."
else
    log_success "Teardown complete. Nothing is left of the mini deployment.

Redeploy with:
  ./scripts/deploy-mini.sh"
fi
