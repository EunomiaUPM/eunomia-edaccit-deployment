AUTHORITY_URL="${AUTHORITY_URL:-http://127.0.0.1:1500}"
CONSUMER_URL="${CONSUMER_URL:-http://127.0.0.1:1100}"
PROVIDER_URL="${PROVIDER_URL:-http://127.0.0.1:1200}"

DOCKER_AUTHORITY_URL="${DOCKER_AUTHORITY_URL:-http://host.docker.internal:1500}"
DOCKER_CONSUMER_URL="${DOCKER_CONSUMER_URL:-http://host.docker.internal:1100}"
DOCKER_PROVIDER_URL="${DOCKER_PROVIDER_URL:-http://host.docker.internal:1200}"

log_step()    { echo -e "\n\033[36m$1\033[0m" >&2; }
log_success() { echo -e "\033[32m$1\033[0m" >&2; }
log_error()   { echo -e "\033[31m$1\033[0m" >&2; exit 1; }
log_info()    { echo -e "\033[33m$1\033[0m" >&2; }

# ---------------------------------------------------------------------------
# ArcGIS environment
# ---------------------------------------------------------------------------
# Loads services/map-viewer/.env and applies the ARCGIS_* defaults.
# Variables already exported in the shell take precedence over the file.
load_arcgis_env() {
    local lib_dir repo_root env_file key value
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "${lib_dir}/.." && pwd)"
    env_file="${repo_root}/services/map-viewer/.env"

    if [[ -f "${env_file}" ]]; then
        while IFS='=' read -r key value; do
            [[ "${key}" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${key// /}" ]] && continue
            key="${key// /}"

            if [[ "${value}" =~ ^[[:space:]]*\"(.*)\"[[:space:]]*$ || \
                  "${value}" =~ ^[[:space:]]*\'(.*)\'[[:space:]]*$ ]]; then
                # Quoted value: take it verbatim, '#' inside is not a comment
                value="${BASH_REMATCH[1]}"
            else
                # Unquoted: ' #' starts an inline comment, then trim whitespace.
                # A bare '#' is kept, so passwords containing it survive.
                value="${value%%[[:space:]]#*}"
                value="${value#"${value%%[![:space:]]*}"}"
                value="${value%"${value##*[![:space:]]}"}"
            fi

            # Only set if the variable is not already in the environment
            if [[ -z "${!key+x}" ]]; then
                export "${key}=${value}"
            fi
        done < "${env_file}"
    fi

    export ARCGIS_PORTAL_URL="${ARCGIS_PORTAL_URL:-https://edaccit.esrilab.es/portal}"
    export ARCGIS_SERVER_URL="${ARCGIS_SERVER_URL:-https://edaccit.esrilab.es/server}"
    export ARCGIS_TOKEN_EXPIRY="${ARCGIS_TOKEN_EXPIRY:-120}"
    export ARCGIS_REFERER="${ARCGIS_REFERER:-https://edaccit.esrilab.es}"
    export ARCGIS_VERIFY_SSL="${ARCGIS_VERIFY_SSL:-true}"
}

curl_raw() {
    local method=${1:-GET}
    local url=$2
    local body=${3:-}
    if [ -n "$body" ]; then
        curl -s -X "$method" "$url" -H "Content-Type: application/json" -d "$body"
    else
        curl -s -X "$method" "$url" -H "Content-Type: application/json"
    fi
}
