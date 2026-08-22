# deploy-mini.ps1 — bring up the whole mini deployment and onboard it
# ====================================================================
# PowerShell port of scripts/deploy-mini.sh. Encodes the same sequence:
#
#   1. git pull                    (you, beforehand)
#   2. $env:API_VALUE = arcgis-token.ps1
#   3. docker compose up  authority -> provider -> consumer -> map-viewer
#   4. mini-onboarding.ps1
#
# Steps 2-4 are what this script does. Everything it runs is idempotent, so
# re-running it after a `git pull` is safe: the catalog is not duplicated and
# participants already registered with the authority are left alone.
#
# Usage:
#   .\scripts-win\deploy-mini.ps1
#   .\scripts-win\deploy-mini.ps1 -NoOnboarding
#   .\scripts-win\deploy-mini.ps1 -NoMapViewer
#   $env:API_VALUE = '<token>'; .\scripts-win\deploy-mini.ps1   # reuse a token

[CmdletBinding()]
param(
    [switch]$NoOnboarding,
    [switch]$NoMapViewer
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

# Returns the processes listening on a TCP port, or an empty array.
# Get-NetTCPConnection is the Windows equivalent of `lsof -iTCP -sTCP:LISTEN`;
# it exists on Windows 8 / Server 2012 and later.
function Get-PortListeners {
    param([int]$Port)

    $result = @()
    $conns = $null
    try {
        $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    } catch {
        return $result
    }
    if ($null -eq $conns) { return $result }

    foreach ($c in @($conns)) {
        $name = 'unknown'
        try {
            $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            if ($null -ne $proc) { $name = $proc.ProcessName }
        } catch { }
        $result += [PSCustomObject]@{ Pid = $c.OwningProcess; Name = $name }
    }
    return $result
}

try {
    $repoRoot = Get-RepoRoot
    $miniDir = Join-Path $repoRoot 'deployment\mini'

    Test-DockerAvailable

    # -----------------------------------------------------------------------
    # Guard: a natively built agent on the same port silently wins over Docker,
    # and the container still looks perfectly healthy.
    # -----------------------------------------------------------------------
    foreach ($port in @(1100, 1200, 1500, 8000)) {
        $listeners = Get-PortListeners -Port $port
        foreach ($l in $listeners) {
            # Docker Desktop publishes ports through its own backend process;
            # anything else holding the port is the problem this guards against.
            if ($l.Name -match 'docker|vpnkit|wslrelay|com\.docker') { continue }
            Stop-WithError "Port $port is taken by a non-Docker process ($($l.Name), PID $($l.Pid)). Stop it before deploying."
        }
    }

    # -----------------------------------------------------------------------
    # Step 1 — ArcGIS token
    # -----------------------------------------------------------------------
    if (-not [string]::IsNullOrWhiteSpace($env:API_VALUE)) {
        Write-Step 'Step 1 - Using API_VALUE from the environment'
    } else {
        Write-Step 'Step 1 - Fetching ArcGIS token'
        # Baked into every connector instance and never refreshed, so ask for
        # the longest lifetime the portal will grant.
        if ([string]::IsNullOrWhiteSpace($env:ARCGIS_TOKEN_EXPIRY)) {
            $env:ARCGIS_TOKEN_EXPIRY = '525600'
        }
        $token = & "$PSScriptRoot\arcgis-token.ps1"
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
            Stop-WithError 'Could not obtain an ArcGIS token.'
        }
        # The script prints progress to the host and the token to stdout, so
        # what lands here is the token alone.
        $env:API_VALUE = ([string]$token).Trim()
    }

    # -----------------------------------------------------------------------
    # Step 2 — Compose stacks
    # -----------------------------------------------------------------------
    Write-Step 'Step 2 - Starting authority'
    Invoke-Docker @('compose', '-f', (Join-Path $miniDir 'docker-compose.mini.heimdall.yaml'), 'up', '-d', '--wait') | Out-Null

    Write-Step 'Step 2 - Starting provider (+ metadata ingestion)'
    Invoke-Docker @('compose', '-f', (Join-Path $miniDir 'docker-compose.mini.provider.yaml'), 'up', '-d') | Out-Null

    Write-Step 'Step 2 - Starting consumer'
    Invoke-Docker @('compose', '-f', (Join-Path $miniDir 'docker-compose.mini.consumer.yaml'), 'up', '-d') | Out-Null

    if (-not $NoMapViewer) {
        Write-Step 'Step 2 - Starting map viewer'
        # --build because the SPA is compiled into the image: Vite bakes the
        # VITE_* vars at build time, so a plain `up` would serve the stale
        # bundle after a pull. Docker's layer cache makes this a no-op when
        # nothing moved.
        Invoke-Docker @('compose', '-f', (Join-Path $miniDir 'docker-compose.mini.map-viewer.yaml'), 'up', '-d', '--build') | Out-Null
    }

    # -----------------------------------------------------------------------
    # Step 3 — Wait for the agents
    # -----------------------------------------------------------------------
    # The agents expose no healthcheck, so compose reports them up the moment
    # the process starts — several seconds before the router answers.
    function Wait-ForService {
        param([string]$Name, [string]$Url, [int]$Retries = 60)
        for ($i = 0; $i -lt $Retries; $i++) {
            if (Test-Endpoint -Url $Url) {
                Write-Ok "$Name is ready"
                return
            }
            Start-Sleep -Seconds 2
        }
        Stop-WithError "$Name did not become ready ($Url)"
    }

    Write-Step 'Step 3 - Waiting for the agents'
    Wait-ForService -Name 'Authority' -Url "$script:AuthorityUrl/readiness"
    Wait-ForService -Name 'Provider'  -Url "$script:ProviderUrl/api/v1/catalog-agent/catalogs/main"
    Wait-ForService -Name 'Consumer'  -Url "$script:ConsumerUrl/api/v1/catalog-agent/catalogs/main"
    if (-not $NoMapViewer) {
        Wait-ForService -Name 'Map viewer' -Url "$script:MapViewerUrl/api/health"
    }

    # -----------------------------------------------------------------------
    # Step 4 — Onboarding
    # -----------------------------------------------------------------------
    if (-not $NoOnboarding) {
        & "$PSScriptRoot\mini-onboarding.ps1"
        if ($LASTEXITCODE -ne 0) { Stop-WithError 'Onboarding failed' }
    } else {
        Write-Note 'Skipping onboarding (-NoOnboarding)'
    }

    Write-Host ''
    $summary = @(
        'Mini deployment ready:',
        "  Authority  : $script:AuthorityUrl/admin/home",
        "  Provider   : $script:ProviderUrl/admin/login",
        "  Consumer   : $script:ConsumerUrl/admin/login"
    )
    if (-not $NoMapViewer) { $summary += "  Map viewer : $script:MapViewerUrl" }
    Write-Ok ($summary -join [Environment]::NewLine)
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
