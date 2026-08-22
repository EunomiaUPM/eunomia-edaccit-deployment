# teardown-mini.ps1 — remove every trace of the mini deployment
# ==============================================================
# PowerShell port of scripts/teardown-mini.sh. The inverse of deploy-mini.ps1:
#
#   1. docker compose down on all five stacks (containers + networks + volumes)
#   2. sweep any stray edaccit-* container or network compose did not own
#   3. wipe the generated identity material under vault\
#   4. verify every port the deployment publishes is free again
#
# Step 3 is what makes this a real reset rather than a restart. The agents'
# DIDs, keys and wallet state live in vault\ through a bind mount, not in a
# Docker volume, so `docker compose down -v` leaves them behind and a redeploy
# silently reuses the old identities.
#
# Only generated files are removed there: vault\ also holds committed .example
# files the deployment needs to boot, and deleting those breaks the repo.
#
# Usage:
#   .\scripts-win\teardown-mini.ps1                  # asks for confirmation
#   .\scripts-win\teardown-mini.ps1 -DryRun          # show what would be removed
#   .\scripts-win\teardown-mini.ps1 -Yes             # no prompt
#   .\scripts-win\teardown-mini.ps1 -Images          # also remove built images
#   .\scripts-win\teardown-mini.ps1 -KeepIdentities  # keep vault\, just stop

[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Images,
    [switch]$KeepIdentities
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

function Invoke-Step {
    param([string[]]$DockerArgs, [switch]$IgnoreFailure)
    if ($DryRun) {
        Write-Host ('  would run: docker ' + ($DockerArgs -join ' '))
        return
    }
    Invoke-Docker -Arguments $DockerArgs -IgnoreFailure:$IgnoreFailure | Out-Null
}

try {
    $repoRoot = Get-RepoRoot
    $miniDir = Join-Path $repoRoot 'deployment\mini'

    Test-DockerAvailable

    # The provider stack declares API_VALUE as a required variable, so compose
    # cannot even parse that file without one — `down` fails just like `up`.
    # The value is never used while tearing down; it only has to exist.
    if ([string]::IsNullOrWhiteSpace($env:API_VALUE)) {
        $env:API_VALUE = 'teardown-placeholder'
    }

    $composeFiles = @(
        (Join-Path $miniDir 'docker-compose.mini.map-viewer.yaml'),
        (Join-Path $miniDir 'docker-compose.mini.consumer.yaml'),
        (Join-Path $miniDir 'docker-compose.mini.provider.yaml'),
        (Join-Path $miniDir 'docker-compose.mini.heimdall.yaml'),
        (Join-Path $repoRoot 'e2e\docker-compose.e2e.yaml')
    )

    # Published by the four stacks: agents, databases and caches.
    $ports = @(1100, 1200, 1300, 1400, 1450, 1500, 6379, 6380, 8000)

    # -----------------------------------------------------------------------
    # Confirmation
    # -----------------------------------------------------------------------
    if (-not $DryRun -and -not $Yes) {
        Write-Host ''
        Write-Note 'This removes the whole mini deployment:'
        Write-Note '  - every edaccit-* container, network and volume'
        Write-Note '  - the catalog and all negotiated agreements (they live in the databases)'
        if (-not $KeepIdentities) {
            Write-Note '  - the generated identities in vault\ - the agents get new DIDs'
        }
        if ($Images) {
            Write-Note '  - the images built for map-viewer, metadata-ingestion and e2e'
        }
        Write-Host ''
        Write-Note 'Redeploying afterwards needs an ArcGIS token, so make sure the'
        Write-Note 'credentials in .env still work before wiping this.'
        Write-Host ''
        $reply = Read-Host "Type 'yes' to continue"
        if ($reply -ne 'yes') { Stop-WithError 'Aborted, nothing was removed.' }
    }

    if ($DryRun) { Write-Note 'DRY RUN - nothing will actually be removed' }

    # -----------------------------------------------------------------------
    # Step 1 — Compose down
    # -----------------------------------------------------------------------
    Write-Step 'Step 1 - Stopping the stacks'

    $downArgs = @('down', '--volumes', '--remove-orphans')
    if ($Images) { $downArgs += @('--rmi', 'local') }

    foreach ($file in $composeFiles) {
        if (-not (Test-Path $file)) {
            Write-Note "Skipping $(Split-Path $file -Leaf) - not found"
            continue
        }
        Write-Note "down: $(Split-Path $file -Leaf)"
        Invoke-Step -DockerArgs (@('compose', '-f', $file) + $downArgs)
    }

    # -----------------------------------------------------------------------
    # Step 2 — Sweep leftovers
    # -----------------------------------------------------------------------
    # Anything started outside compose, or left behind by an interrupted run,
    # is invisible to `down` but still holds its name and port.
    Write-Step 'Step 2 - Sweeping stray containers and networks'

    $stray = @(& docker ps -aq --filter 'name=^/edaccit-' | Where-Object { $_ })
    if ($stray.Count -gt 0) {
        Write-Note "Removing $($stray.Count) leftover container(s)"
        Invoke-Step -DockerArgs (@('rm', '-f') + $stray) -IgnoreFailure
    } else {
        Write-Ok 'No stray containers'
    }

    $strayNet = @(& docker network ls -q --filter 'name=edaccit' | Where-Object { $_ })
    if ($strayNet.Count -gt 0) {
        Write-Note "Removing $($strayNet.Count) leftover network(s)"
        Invoke-Step -DockerArgs (@('network', 'rm') + $strayNet) -IgnoreFailure
    } else {
        Write-Ok 'No stray networks'
    }

    # The stacks declare no named volumes today (the databases write to the
    # container layer), but --volumes above plus this check keeps the teardown
    # honest if one is ever added.
    $strayVol = @(& docker volume ls -q --filter 'name=edaccit' | Where-Object { $_ })
    if ($strayVol.Count -gt 0) {
        Write-Note 'Removing leftover volume(s)'
        Invoke-Step -DockerArgs (@('volume', 'rm') + $strayVol) -IgnoreFailure
    } else {
        Write-Ok 'No stray volumes'
    }

    # -----------------------------------------------------------------------
    # Step 3 — Generated identity material
    # -----------------------------------------------------------------------
    Write-Step 'Step 3 - Wiping generated state in vault\'

    $vaultDir = Join-Path $repoRoot 'vault'
    $hasGit = $false
    if (Get-Command git -ErrorAction SilentlyContinue) {
        & git -C $repoRoot rev-parse --is-inside-work-tree 2>&1 | Out-Null
        $hasGit = ($LASTEXITCODE -eq 0)
    }

    if ($KeepIdentities) {
        Write-Note 'Keeping vault\ (-KeepIdentities) - the agents will reuse their DIDs'
    } elseif (-not (Test-Path $vaultDir)) {
        Write-Note 'No vault\ directory, nothing to wipe'
    } elseif ($hasGit) {
        # git knows exactly which files are committed and which the deployment
        # generated, so it draws the line for us. -x includes ignored files,
        # which is where the generated keys live; tracked files are untouched.
        # LC_ALL=C because this parses git's output, which is translated.
        $env:LC_ALL = 'C'
        $pending = @(& git -C $repoRoot clean -ndx -- vault/ | Where-Object { $_ })
        if ($pending.Count -eq 0) {
            Write-Ok 'vault\ is already clean'
        } else {
            foreach ($line in $pending) {
                Write-Host ('  ' + ($line -replace '^Would remove ', ''))
            }
            if ($DryRun) {
                Write-Host '  would run: git clean -fdx -- vault/'
            } else {
                & git -C $repoRoot clean -fdx -- vault/ | Out-Null
                if ($LASTEXITCODE -ne 0) { Stop-WithError 'git clean failed on vault/' }
            }
            Write-Ok 'Generated identity material removed'
        }
    } else {
        # Not a git checkout (a copied directory on the production box, say),
        # so fall back to the filenames the setup jobs are known to generate.
        Write-Note 'Not a git checkout - removing the known generated files'
        foreach ($participant in @('consumer', 'provider', 'heimdall')) {
            foreach ($name in @('cert.json.example', 'private_key.json.example', 'public_key.json.example')) {
                $target = Join-Path $vaultDir "$participant\secrets\$name"
                if (Test-Path $target) {
                    if ($DryRun) { Write-Host "  would remove: $target" }
                    else { Remove-Item -LiteralPath $target -Force }
                }
            }
            $dataDir = Join-Path $vaultDir "$participant\data"
            if (Test-Path $dataDir) {
                # .gitkeep is committed and keeps the directory present.
                Get-ChildItem -LiteralPath $dataDir -Force | Where-Object { $_.Name -ne '.gitkeep' } | ForEach-Object {
                    if ($DryRun) { Write-Host "  would remove: $($_.FullName)" }
                    else { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
                }
            }
        }
        Write-Ok 'Generated identity material removed'
    }

    # -----------------------------------------------------------------------
    # Step 4 — Ports
    # -----------------------------------------------------------------------
    Write-Step 'Step 4 - Checking the ports are free'

    if ($DryRun) {
        Write-Note 'Skipped in dry-run mode'
    } else {
        $busy = $false
        foreach ($port in $ports) {
            $conns = $null
            try {
                $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
            } catch { }
            if ($null -ne $conns -and @($conns).Count -gt 0) {
                $busy = $true
                foreach ($c in @($conns)) {
                    $name = 'unknown'
                    try {
                        $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
                        if ($null -ne $proc) { $name = $proc.ProcessName }
                    } catch { }
                    Write-Note "Port $port is still in use by $name (PID $($c.OwningProcess))"
                }
            }
        }
        if ($busy) {
            # deploy-mini.ps1 refuses to start when a non-Docker process squats
            # on one of these, so surface it now rather than at the next deploy.
            Stop-WithError 'Some ports are still held. Stop the process above before redeploying.'
        }
        Write-Ok "All $($ports.Count) ports are free"
    }

    Write-Host ''
    if ($DryRun) {
        Write-Ok 'Dry run complete - nothing was removed.'
    } else {
        Write-Ok "Teardown complete. Nothing is left of the mini deployment.`n`nRedeploy with:`n  .\scripts-win\deploy-mini.ps1"
    }
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
