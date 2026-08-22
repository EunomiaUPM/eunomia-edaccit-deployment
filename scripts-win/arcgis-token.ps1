# arcgis-token.ps1 — fetch an ArcGIS token and write it to stdout
# ================================================================
# PowerShell port of scripts/arcgis-token.sh.
#
# Writes ONLY the token to stdout; all progress messages go to the host, so the
# output can be captured directly:
#
#   $env:API_VALUE = (.\scripts-win\arcgis-token.ps1)
#
# Credentials are read from the repo-root .env. Any variable already set in the
# environment takes precedence over the file.
#
# Usage:
#   .\scripts-win\arcgis-token.ps1
#   $env:ARCGIS_TOKEN_EXPIRY = '1440'; .\scripts-win\arcgis-token.ps1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

try {
    $repoRoot = Get-RepoRoot
    Import-ArcgisEnv -RepoRoot $repoRoot

    $username = [Environment]::GetEnvironmentVariable('ARCGIS_USERNAME')
    $password = [Environment]::GetEnvironmentVariable('ARCGIS_PASSWORD')
    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
        Stop-WithError 'ARCGIS_USERNAME and ARCGIS_PASSWORD must be set (via the environment or the repo-root .env)'
    }

    $portal   = [Environment]::GetEnvironmentVariable('ARCGIS_PORTAL_URL')
    $referer  = [Environment]::GetEnvironmentVariable('ARCGIS_REFERER')
    $expiry   = [Environment]::GetEnvironmentVariable('ARCGIS_TOKEN_EXPIRY')
    $insecure = ([Environment]::GetEnvironmentVariable('ARCGIS_VERIFY_SSL') -eq 'false')

    Set-InsecureTls -Enabled $insecure
    $extra = Get-InsecureRestArgs -Insecure $insecure

    Write-Note "Portal : $portal"
    Write-Note "User   : $username"

    # The portal expects a form post, not JSON.
    $form = @{
        f          = 'json'
        username   = $username
        password   = $password
        client     = 'referer'
        referer    = $referer
        expiration = $expiry
    }

    $response = Invoke-RestMethod -Method Post -Uri "$portal/sharing/rest/generateToken" `
        -Body $form -TimeoutSec 60 @extra

    $token = $null
    if ($response.PSObject.Properties.Name -contains 'token') { $token = $response.token }

    if ([string]::IsNullOrWhiteSpace($token)) {
        $dump = ($response | ConvertTo-Json -Depth 10 -Compress)
        Stop-WithError "Token generation failed. Response: $dump"
    }

    # Report the lifetime the portal actually granted, not the one requested:
    # it silently clamps expiration to its own maximum.
    $granted = ''
    if ($response.PSObject.Properties.Name -contains 'expires') {
        $epoch = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$response.expires)
        $minutes = [Math]::Floor(($epoch - [DateTimeOffset]::UtcNow).TotalMinutes)
        $granted = [string]$minutes
    }

    if (-not [string]::IsNullOrWhiteSpace($granted) -and $granted -ne $expiry) {
        Write-Ok "Token obtained (valid $granted min - the portal capped the $expiry min requested)"
    } elseif (-not [string]::IsNullOrWhiteSpace($granted)) {
        Write-Ok "Token obtained (valid $granted min)"
    } else {
        Write-Ok "Token obtained (valid $expiry min)"
    }

    # The token — and nothing else — on stdout.
    Write-Output $token
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
