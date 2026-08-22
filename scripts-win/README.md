# Windows scripts

PowerShell port of everything in [`scripts/`](../scripts/), for the Windows host where `bash` is not available and WSL is not an option.

Requires **Docker Desktop** and nothing else. No `bash`, no `jq`, no `curl`, no Python — the bash scripts shell out to all four, and none of them ship with Windows, so every one of those calls was replaced with a native PowerShell equivalent.

Targets **Windows PowerShell 5.1**, which is what Windows Server ships with. The scripts also run unchanged on PowerShell 7.

## Running them

Double-click or run the `.bat` launcher — it is the safe path, because a stock Windows Server refuses to run `.ps1` files at all (`ExecutionPolicy` is `Restricted` by default) and the launcher bypasses that for the one script it starts:

```bat
scripts-win\deploy-mini.bat
scripts-win\teardown-mini.bat
scripts-win\smoke-test.bat
scripts-win\ingest.bat
```

Arguments are forwarded:

```bat
scripts-win\deploy-mini.bat -NoMapViewer
scripts-win\teardown-mini.bat -DryRun
```

From an already-open PowerShell window you can call the scripts directly, as long as the policy allows it:

```powershell
.\scripts-win\deploy-mini.ps1
powershell -ExecutionPolicy Bypass -File .\scripts-win\deploy-mini.ps1   # if it does not
```

## What maps to what

| Bash | PowerShell | Notes |
| ---- | ---------- | ----- |
| `deploy-mini.sh` | `deploy-mini.ps1` | `--no-onboarding` → `-NoOnboarding`, `--no-map-viewer` → `-NoMapViewer` |
| `teardown-mini.sh` | `teardown-mini.ps1` | `--dry-run` → `-DryRun`, `--yes` → `-Yes`, `--images` → `-Images`, `--keep-identities` → `-KeepIdentities` |
| `mini-onboarding.sh` | `mini-onboarding.ps1` | |
| `register-with-authority.sh` | `register-with-authority.ps1` | `PARTICIPANT_URL` → `-ParticipantUrl`, `PARTICIPANT_NICK` → `-Nick` |
| `authenticate-participants.sh` | `authenticate-participants.ps1` | |
| `arcgis-token.sh` | `arcgis-token.ps1` | Writes the token to stdout, everything else to the host |
| `smoke-test.sh` | `smoke-test.ps1` | |
| `ingest.sh` + `ingest-arcgis-token.sh` | `ingest.ps1` | One script; see the caveat below |
| `gaia.sh` | `gaia.ps1` | |
| `lib.sh` | `lib.ps1` | Dot-sourced by the rest |

Environment overrides work the same way, since they are read from the environment either way:

```powershell
$env:CONSUMER_URL = 'http://127.0.0.1:1100'
$env:PROVIDER_URL = 'http://127.0.0.1:1200'
.\scripts-win\mini-onboarding.ps1
```

Capturing the token works like the bash idiom, because the script keeps stdout clean:

```powershell
$env:API_VALUE = (.\scripts-win\arcgis-token.ps1)
```

## One real difference: `ingest.ps1`

The bash pipeline runs three Python scripts on the host: `convert_metadata.py` and `convert_connectors.py` regenerate the payload files from the source JSON-LD, then `populate_catalog.py` POSTs them.

Windows has no Python, so `ingest.ps1` drives the **metadata-ingestion container** instead — the same one the provider stack already runs on `up`. The catalog ends up identical.

What it does **not** do is regenerate the payloads. Those are committed to the repo, so they only need regenerating when the source metadata changes, which is a development task rather than a deployment one. If you ever need it, run the bash pipeline on a machine that has Python.

Normal deployments do not need `ingest.ps1` at all: `deploy-mini.ps1` brings up the provider stack, which ingests the catalog on its own.

## Notes on the port checks

`deploy-mini.ps1` refuses to start when something other than Docker is listening on 1100, 1200, 1500 or 8000, and `teardown-mini.ps1` verifies all nine published ports are free when it finishes. Both use `Get-NetTCPConnection`, the Windows equivalent of `lsof`, available on Windows 8 / Server 2012 and later. On a machine without it the check is skipped rather than failing the run.

## Verification status

Every script here was parsed and exercised with a real PowerShell interpreter: syntax checks pass on all ten, the `.env` parser was tested against the bash original and matches on all edge cases (quoted values, inline comments, `#` inside passwords), and the HTTP layer was run against a live agent for success, 404 and connection-refused paths.

They have **not** been run on Windows itself. The Windows-only surface is `Get-NetTCPConnection`, `Read-Host`, the `.bat` launchers and the PowerShell 5.1 engine; the first run on the target machine is still the real test.
