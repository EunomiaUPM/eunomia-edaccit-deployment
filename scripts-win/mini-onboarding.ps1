# mini-onboarding.ps1 — link wallets, register participants, authenticate them
# =============================================================================
# PowerShell port of scripts/mini-onboarding.sh. Safe to re-run: every step
# below skips itself when already done.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

try {
    Write-Host ''
    Write-Host '======================================' -ForegroundColor Cyan
    Write-Host '         FULL ONBOARDING'             -ForegroundColor Cyan
    Write-Host '======================================' -ForegroundColor Cyan

    Write-Step 'Linking wallets'
    $null = Invoke-ApiChecked -Method POST -Url "$script:AuthorityUrl/api/v1/wallet/link"
    $null = Invoke-ApiChecked -Method POST -Url "$script:ConsumerUrl/api/v1/wallet/link"
    $null = Invoke-ApiChecked -Method POST -Url "$script:ProviderUrl/api/v1/wallet/link"
    Write-Ok 'Wallets linked'

    # Each step runs in its own process so a non-zero exit is visible here; a
    # dot-sourced script would exit this one instead.
    & "$PSScriptRoot\register-with-authority.ps1" -ParticipantUrl $script:ConsumerUrl -Nick 'consumer'
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'Registering the consumer failed' }

    & "$PSScriptRoot\register-with-authority.ps1" -ParticipantUrl $script:ProviderUrl -Nick 'provider'
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'Registering the provider failed' }

    & "$PSScriptRoot\authenticate-participants.ps1"
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'Authenticating the participants failed' }

    Write-Host ''
    Write-Host '======================================' -ForegroundColor Green
    Write-Host '   ONBOARDING FINISHED SUCCESSFULLY'  -ForegroundColor Green
    Write-Host '======================================' -ForegroundColor Green
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
