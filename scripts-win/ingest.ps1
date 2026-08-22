# ingest.ps1 — populate the provider catalog
# ===========================================
# PowerShell equivalent of scripts/ingest.sh + scripts/ingest-arcgis-token.sh.
#
# The bash pipeline runs three Python scripts on the host. Windows has no
# Python, so this drives the metadata-ingestion **container** instead — the
# same one the provider stack already runs on `up`, so the result is identical:
#
#   1. Fetch an ArcGIS token (unless -ApiValue is given).
#   2. docker compose run --rm metadata-ingestion → populate_catalog.py
#
# What this does NOT do, unlike the bash version: regenerate the payload files
# from the source JSON-LD metadata (convert_metadata.py / convert_connectors.py).
# Those payloads are committed to the repo, so they only need regenerating when
# the source metadata changes — which is a development task, not a deployment
# one, and needs Python.
#
# Datasets are matched by title against what the provider already holds, so
# re-running against a populated catalog is a no-op rather than a duplication.
#
# Usage:
#   .\scripts-win\ingest.ps1
#   .\scripts-win\ingest.ps1 -ApiValue '<token>'
#   .\scripts-win\ingest.ps1 -Force        # re-POST everything
#   .\scripts-win\ingest.ps1 -DryRun       # print payloads, call nothing

[CmdletBinding()]
param(
    [string]$ApiValue,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

try {
    $repoRoot = Get-RepoRoot
    $providerCompose = Join-Path $repoRoot 'deployment\mini\docker-compose.mini.provider.yaml'

    Test-DockerAvailable

    if (-not (Test-Path $providerCompose)) {
        Stop-WithError "Provider compose file not found: $providerCompose"
    }

    # -----------------------------------------------------------------------
    # Step 1 — ArcGIS token
    # -----------------------------------------------------------------------
    if (-not [string]::IsNullOrWhiteSpace($ApiValue)) {
        Write-Step 'Step 1 - Using the token passed in -ApiValue'
        $env:API_VALUE = $ApiValue.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($env:API_VALUE)) {
        Write-Step 'Step 1 - Using API_VALUE from the environment'
    } else {
        Write-Step 'Step 1 - Fetching ArcGIS token'
        # The token is baked into every connector instance at POST time and
        # nothing refreshes it afterwards, so ask for a long-lived one (1 year).
        # The portal may silently clamp this to its own maximum.
        if ([string]::IsNullOrWhiteSpace($env:ARCGIS_TOKEN_EXPIRY)) {
            $env:ARCGIS_TOKEN_EXPIRY = '525600'
        }
        $token = & "$PSScriptRoot\arcgis-token.ps1"
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
            Stop-WithError 'Could not obtain an ArcGIS token.'
        }
        $env:API_VALUE = ([string]$token).Trim()
    }

    # -----------------------------------------------------------------------
    # Step 2 — Run the ingestion container
    # -----------------------------------------------------------------------
    Write-Step 'Step 2 - Running the ingestion container'

    # --provider-url uses the compose service name because the container joins
    # the provider stack's own network; host.docker.internal would work too but
    # would leave the request going out and back in.
    $runArgs = @(
        'compose', '-f', $providerCompose,
        'run', '--rm', 'metadata-ingestion',
        '--provider-url', 'http://provider:1200'
    )
    if ($Force)  { $runArgs += '--force' }
    if ($DryRun) { $runArgs += '--dry-run' }

    Invoke-Docker -Arguments $runArgs | Out-Null

    Write-Ok 'Ingestion finished'
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
