# authenticate-participants.ps1 — GNAP handshake, consumer → provider
# =====================================================================
# PowerShell port of scripts/authenticate-participants.sh.

[CmdletBinding()]
param(
    [string]$ProviderNick = 'provider'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

try {
    Write-Step "Authenticating consumer with provider ($ProviderNick)"

    $providerDid = (Invoke-ApiChecked -Method GET -Url "$script:ProviderUrl/.well-known/did.json").id

    # Check for the token, not for the mate: an untokened mate row means the
    # handshake never completed.
    $mates = Invoke-ApiRaw -Method GET -Url "$script:ConsumerUrl/api/v1/mates/all"
    if ($null -ne $mates) {
        foreach ($mate in @($mates)) {
            if ($mate.participant_id -ne $providerDid) { continue }
            $token = ''
            if ($mate.PSObject.Properties.Name -contains 'token' -and $null -ne $mate.token) {
                $token = [string]$mate.token
            }
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                Write-Note 'Consumer is already authenticated with the provider, skipping'
                exit 0
            }
        }
    }

    # This is the GNAP handshake, and it is what mints the mate token. Creating
    # the mate directly via POST /api/v1/mates is NOT equivalent: it only inserts
    # the row, leaving it tokenless, and the provider then answers 401 to every
    # DSP call (surfaced as 502 by the consumer BFF).
    $body = @{
        id      = $providerDid
        nick    = $ProviderNick
        url     = "$script:DockerProviderUrl/api/v1/gate/access"
        actions = @('talk')
        auto    = $true
    }

    $null = Invoke-ApiChecked -Method POST -Url "$script:ConsumerUrl/api/v1/peer-connection/connect" -Body $body
    Write-Ok 'Authentication complete'
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
