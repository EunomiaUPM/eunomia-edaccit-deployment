# gaia.ps1 — GAIA-X credential flow
# ==================================
# PowerShell port of scripts/gaia.sh.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

# Every call here mutates state, so all of them go through Invoke-ApiChecked
# and a failure stops the flow instead of carrying on with a broken step.
function Invoke-Gaia {
    param([string]$Method, [string]$Url, $Body = $null)
    $result = Invoke-ApiChecked -Method $Method -Url $Url -Body $Body
    Write-Ok "OK: $Method $Url"
    return $result
}

try {
    Write-Host ''
    Write-Host '======================================' -ForegroundColor Cyan
    Write-Host '        GAIA LOCAL FLOW'              -ForegroundColor Cyan
    Write-Host '======================================' -ForegroundColor Cyan

    Write-Step 'STEP 1 - Linking wallets'
    $null = Invoke-Gaia POST "$script:ConsumerUrl/api/v1/wallet/link"
    $null = Invoke-Gaia POST "$script:ProviderUrl/api/v1/wallet/link"
    $null = Invoke-Gaia POST "$script:AuthorityUrl/api/v1/wallet/link"

    Write-Step 'STEP 2 - Retrieving DIDs'
    $consumerDid  = (Invoke-Gaia GET "$script:ConsumerUrl/.well-known/did.json").id
    $providerDid  = (Invoke-Gaia GET "$script:ProviderUrl/.well-known/did.json").id
    $authorityDid = (Invoke-Gaia GET "$script:AuthorityUrl/.well-known/did.json").id
    Write-Note "Consumer DID:  $consumerDid"
    Write-Note "Provider DID:  $providerDid"
    Write-Note "Authority DID: $authorityDid"

    Write-Step 'STEP 3 - Requesting Legal VC'
    $legalBody = @{
        url     = "$script:DockerAuthorityUrl/api/v1/gate/access"
        id      = $authorityDid
        slug    = 'authority'
        vc_type = 'gx_VatId_jwt_vc_json'
        method  = 'cert'
        auto    = $true
    }
    $null = Invoke-Gaia POST "$script:ConsumerUrl/api/v1/vc-request/beg" $legalBody

    Write-Step 'STEP 6 - Generating Gaia VCs'
    $null = Invoke-Gaia POST "$script:ConsumerUrl/api/v1/gaia/credential/generate"

    Write-Step 'STEP 7 - Requesting Label VC'
    $labelBody = @{
        url     = "$script:DockerAuthorityUrl/api/v1/gate/access"
        id      = $authorityDid
        slug    = 'authority'
        vc_type = 'gx_LabelCredential_jwt_vc_json'
        method  = 'oidc4vp'
        auto    = $true
    }
    $null = Invoke-Gaia POST "$script:ConsumerUrl/api/v1/vc-request/beg" $labelBody

    Write-Step 'STEP 8 - Talking to Provider'
    $providerBody = @{
        url     = "$script:DockerProviderUrl/api/v1/gate/access"
        id      = $providerDid
        slug    = 'provider'
        actions = @('talk')
        auto    = $true
    }
    $null = Invoke-Gaia POST "$script:ConsumerUrl/api/v1/onboard/provider" $providerBody

    Write-Host ''
    Write-Host '======================================' -ForegroundColor Green
    Write-Host '     GAIA FLOW COMPLETED'             -ForegroundColor Green
    Write-Host '======================================' -ForegroundColor Green
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
