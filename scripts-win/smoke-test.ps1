# smoke-test.ps1 — end-to-end ArcGIS connectivity check
# ======================================================
# PowerShell port of scripts/smoke-test.sh.
#
#   1. Generates a token via the ESRILab portal.
#   2. Queries the FeatureServer to confirm the layer is accessible.
#
# Credentials are loaded from the repo-root .env. Any variable already set in
# the environment takes precedence over the file.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

try {
    $repoRoot = Get-RepoRoot
    # Needed here for ARCGIS_SERVER_URL / ARCGIS_VERIFY_SSL in step 2;
    # arcgis-token.ps1 loads it again on its own for the credentials.
    Import-ArcgisEnv -RepoRoot $repoRoot

    $serverUrl = [Environment]::GetEnvironmentVariable('ARCGIS_SERVER_URL')
    $insecure  = ([Environment]::GetEnvironmentVariable('ARCGIS_VERIFY_SSL') -eq 'false')

    Set-InsecureTls -Enabled $insecure
    $extra = Get-InsecureRestArgs -Insecure $insecure

    $layerPath = '/rest/services/Hosted/Fuente1_Infraestructuraferroviaria/FeatureServer/0'

    # -----------------------------------------------------------------------
    # Step 1 — Generate token
    # -----------------------------------------------------------------------
    Write-Step 'Step 1 - Generating token'

    $token = & "$PSScriptRoot\arcgis-token.ps1"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        Stop-WithError 'Could not obtain an ArcGIS token.'
    }
    $token = ([string]$token).Trim()
    Write-Note "Token : $token"

    # -----------------------------------------------------------------------
    # Step 2 — Query FeatureServer
    # -----------------------------------------------------------------------
    Write-Step 'Step 2 - Querying FeatureServer'
    Write-Note "Layer: $serverUrl$layerPath"

    $query = "$serverUrl$layerPath/query?where=1%3D1&outFields=*&f=geojson&resultRecordCount=3&token=$token"
    $response = Invoke-RestMethod -Uri $query -TimeoutSec 60 @extra

    # ArcGIS answers 200 with an embedded error object rather than an HTTP
    # error code, so the body has to be inspected.
    if ($response.PSObject.Properties.Name -contains 'error') {
        Stop-WithError "Layer query failed: $($response.error.message)"
    }

    $count = 0
    if ($response.PSObject.Properties.Name -contains 'features' -and $null -ne $response.features) {
        $count = @($response.features).Count
    }

    if ($count -gt 0) {
        Write-Ok "Received $count feature(s) - layer is accessible"
    } else {
        Stop-WithError 'Query returned 0 features.'
    }

    Write-Step 'Smoke test passed'
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
