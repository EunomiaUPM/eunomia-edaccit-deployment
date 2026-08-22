# register-with-authority.ps1 — get one participant a credential from Heimdall
# =============================================================================
# PowerShell port of scripts/register-with-authority.sh.
#
# Usage:
#   .\scripts-win\register-with-authority.ps1 -ParticipantUrl http://127.0.0.1:1100 -Nick consumer

[CmdletBinding()]
param(
    [string]$ParticipantUrl,
    [string]$Nick = 'participant'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

try {
    if ([string]::IsNullOrWhiteSpace($ParticipantUrl)) {
        $ParticipantUrl = Get-EnvOrDefault 'PARTICIPANT_URL' ''
    }
    if ([string]::IsNullOrWhiteSpace($ParticipantUrl)) {
        Stop-WithError 'ParticipantUrl is required (pass -ParticipantUrl or set PARTICIPANT_URL)'
    }

    Write-Step "Registering $Nick with authority"

    $vcType = 'DataSpaceParticipant_jwt_vc_json'

    $authDid = (Invoke-ApiChecked -Method GET -Url "$script:AuthorityUrl/.well-known/did.json").id

    # /vc-request/beg never deduplicates: every call files a fresh petition with
    # the authority, so without this guard each run piles up another one.
    $existing = Invoke-ApiRaw -Method GET -Url "$ParticipantUrl/api/v1/vc-request/all"
    if ($null -ne $existing) {
        foreach ($req in @($existing)) {
            if ($req.participant_id -ne $authDid) { continue }
            if ($req.status -ne 'Finalized') { continue }
            $types = @()
            if ($req.PSObject.Properties.Name -contains 'vc_type_config' -and $null -ne $req.vc_type_config) {
                $types = @($req.vc_type_config)
            }
            if ($types -contains $vcType) {
                Write-Note "$Nick already holds the credential, skipping"
                exit 0
            }
        }
    }

    # The field is "nick", not "slug": sending "slug" fails with
    # HTTP 400 "Error extracting Json payload".
    $body = @{
        url     = "$script:DockerAuthorityUrl/api/v1/gate/access"
        id      = $authDid
        nick    = 'authority'
        vc_type = $vcType
        method  = 'cert'
        auto    = $true
    }

    $null = Invoke-ApiChecked -Method POST -Url "$ParticipantUrl/api/v1/vc-request/beg" -Body $body
    Write-Ok "$Nick registered successfully"
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
