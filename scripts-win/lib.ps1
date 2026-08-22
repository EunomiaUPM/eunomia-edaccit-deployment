# lib.ps1 — shared helpers for the Windows scripts
# =================================================
# PowerShell port of scripts/lib.sh. Dot-source it:
#
#   . "$PSScriptRoot\lib.ps1"
#
# Targets Windows PowerShell 5.1, which is what Windows Server ships with, so
# nothing here uses PowerShell 7 syntax (no ternary, no ??, no pipeline chain
# operators). It also runs unchanged on PowerShell 7.
#
# There is no curl or jq on a stock Windows box, so every HTTP call goes
# through Invoke-RestMethod and JSON is handled as native objects.

Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------
# Windows PowerShell 5.1 negotiates SSL3/TLS1.0 by default, which the ArcGIS
# portal rejects. Without this the token call fails with a connection error
# that looks like a network problem rather than a protocol one.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # PowerShell 7 on .NET Core manages this itself and may refuse the write.
}

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
function Get-EnvOrDefault {
    param([string]$Name, [string]$Default)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

$script:AuthorityUrl = Get-EnvOrDefault 'AUTHORITY_URL' 'http://127.0.0.1:1500'
$script:ConsumerUrl  = Get-EnvOrDefault 'CONSUMER_URL'  'http://127.0.0.1:1100'
$script:ProviderUrl  = Get-EnvOrDefault 'PROVIDER_URL'  'http://127.0.0.1:1200'
$script:MapViewerUrl = Get-EnvOrDefault 'MAP_VIEWER_URL' 'http://127.0.0.1:8000'

# Addresses as seen from inside a container, for anything that travels in a
# DSP message: 127.0.0.1 there would point the peer at itself.
$script:DockerAuthorityUrl = Get-EnvOrDefault 'DOCKER_AUTHORITY_URL' 'http://host.docker.internal:1500'
$script:DockerConsumerUrl  = Get-EnvOrDefault 'DOCKER_CONSUMER_URL'  'http://host.docker.internal:1100'
$script:DockerProviderUrl  = Get-EnvOrDefault 'DOCKER_PROVIDER_URL'  'http://host.docker.internal:1200'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# Everything goes to the host rather than the pipeline: functions here must be
# able to log without polluting what their caller captures. Write-Host is the
# right tool for that in 5.1, where Write-Information is not shown by default.
function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Write-Note {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
}

# Fatal error. Throws rather than calling exit so a caller can catch it; the
# script entry points turn it into exit code 1.
function Stop-WithError {
    param([string]$Message)
    throw $Message
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
# Skipping certificate validation works differently across versions: 5.1 has no
# -SkipCertificateCheck, so it needs a callback on ServicePointManager, while
# 7 ignores that callback and needs the parameter.
function Set-InsecureTls {
    param([bool]$Enabled)
    if (-not $Enabled) { return }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
}

function Get-InsecureRestArgs {
    param([bool]$Insecure)
    $extra = @{}
    if ($Insecure -and $PSVersionTable.PSVersion.Major -ge 6) {
        $extra['SkipCertificateCheck'] = $true
    }
    return $extra
}

# Returns the parsed JSON body, or $null when the call fails. The mirror of
# curl_raw in lib.sh: errors are swallowed on purpose, for probing.
function Invoke-ApiRaw {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory = $true)][string]$Url,
        $Body = $null
    )
    try {
        return Invoke-ApiChecked -Method $Method -Url $Url -Body $Body
    } catch {
        return $null
    }
}

# Returns the parsed JSON body and throws on any non-2xx response.
#
# Prefer this for anything that mutates state: Invoke-ApiRaw hides failures, so
# a broken step would go unnoticed and the script would still report success.
function Invoke-ApiChecked {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory = $true)][string]$Url,
        $Body = $null,
        [int]$TimeoutSec = 60
    )

    $params = @{
        Method      = $Method
        Uri         = $Url
        ContentType = 'application/json'
        TimeoutSec  = $TimeoutSec
    }

    if ($null -ne $Body) {
        if ($Body -is [string]) {
            $params['Body'] = $Body
        } else {
            # -Depth 20 because the DSP payloads nest well past the default of 2,
            # which would silently serialise deeper objects as type names.
            $params['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress)
        }
    }

    try {
        return Invoke-RestMethod @params
    } catch {
        $detail = Get-HttpErrorDetail $_
        throw "$Method $Url -> $detail"
    }
}

# Pulls the status code and response body out of a failed Invoke-RestMethod.
# The two PowerShell generations expose it differently, and without the body a
# 400 from the agents says nothing about which field it rejected.
function Get-HttpErrorDetail {
    param($ErrorRecord)

    $status = ''
    $body = ''

    $response = $null
    try { $response = $ErrorRecord.Exception.Response } catch { }

    if ($null -ne $response) {
        try { $status = [int]$response.StatusCode } catch { }
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        try { $body = $ErrorRecord.ErrorDetails.Message } catch { }
    } elseif ($null -ne $response) {
        try {
            $stream = $response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
        } catch { }
    }

    if ([string]::IsNullOrWhiteSpace($body)) { $body = $ErrorRecord.Exception.Message }
    if ($body.Length -gt 600) { $body = $body.Substring(0, 600) }

    if ([string]::IsNullOrWhiteSpace($status)) { return $body }
    return "HTTP $status`n$body"
}

# True when the URL answers with any 2xx. Used to wait for the agents, which
# expose no healthcheck and are reported "up" by compose before they listen.
function Test-Endpoint {
    param([string]$Url, [int]$TimeoutSec = 5)
    try {
        $null = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# ArcGIS environment
# ---------------------------------------------------------------------------
# Loads the repo-root .env and applies the ARCGIS_* defaults, mirroring
# load_arcgis_env in lib.sh. Variables already set in the environment win over
# the file, so a value passed on the command line is never overwritten.
function Import-ArcgisEnv {
    param([string]$RepoRoot)

    $envFile = Join-Path $RepoRoot '.env'
    if (Test-Path $envFile) {
        foreach ($line in (Get-Content -LiteralPath $envFile)) {
            if ($line -match '^\s*#') { continue }
            if ($line -notmatch '=') { continue }

            $key = $line.Substring(0, $line.IndexOf('=')).Trim()
            $value = $line.Substring($line.IndexOf('=') + 1)
            if ([string]::IsNullOrWhiteSpace($key)) { continue }

            if ($value -match '^\s*"(.*)"\s*$' -or $value -match "^\s*'(.*)'\s*$") {
                # Quoted: taken verbatim, so a '#' inside is not a comment.
                $value = $Matches[1]
            } else {
                # Unquoted: ' #' starts an inline comment. A bare '#' is kept,
                # so passwords containing one survive.
                $value = ($value -replace '\s+#.*$', '').Trim()
            }

            if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($key))) {
                [Environment]::SetEnvironmentVariable($key, $value)
            }
        }
    }

    $defaults = @{
        'ARCGIS_PORTAL_URL'   = 'https://edaccit.esrilab.es/portal'
        'ARCGIS_SERVER_URL'   = 'https://edaccit.esrilab.es/server'
        'ARCGIS_TOKEN_EXPIRY' = '120'
        'ARCGIS_REFERER'      = 'https://edaccit.esrilab.es'
        'ARCGIS_VERIFY_SSL'   = 'true'
    }
    foreach ($key in $defaults.Keys) {
        if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($key))) {
            [Environment]::SetEnvironmentVariable($key, $defaults[$key])
        }
    }
}

# ---------------------------------------------------------------------------
# Repo layout
# ---------------------------------------------------------------------------
function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------
# docker exits non-zero on failure but PowerShell does not stop for native
# commands, so every call has to check $LASTEXITCODE explicitly or failures
# pass silently and the script reports success.
function Invoke-Docker {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$IgnoreFailure
    )
    & docker @Arguments
    if ($LASTEXITCODE -ne 0 -and -not $IgnoreFailure) {
        Stop-WithError ("docker " + ($Arguments -join ' ') + " failed with exit code $LASTEXITCODE")
    }
    return $LASTEXITCODE
}

function Test-DockerAvailable {
    $null = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $?) {
        Stop-WithError 'docker was not found on PATH. Install Docker Desktop and reopen this window.'
    }
    & docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError 'The Docker daemon is not responding. Start Docker Desktop and try again.'
    }
}
