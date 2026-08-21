# End-to-end test

Runs the complete dataspace flow against a live deployment — contract negotiation, transfer, and a real data fetch through the dataplane proxy — and exits non-zero on the first failure.

Everything runs inside a container, so **Docker Desktop is the only requirement**. No Python, no `bash`, no `jq` on the machine.

## Running it

There are two entry points. Both run the same flow; they differ only in what happens to the transfer at the end.

| Script             | Ends at     | Use it for                                                       |
| ------------------ | ----------- | ---------------------------------------------------------------- |
| `run-complete`     | `COMPLETED` | Verifying the system works. Full lifecycle, nothing left behind.  |
| `run-keep-open`    | `STARTED`   | Demos. Leaves the transfer live and prints the dataplane proxy URL to paste into the Map Viewer. |

On Windows, from `cmd` or PowerShell:

```bat
e2e\run-complete.bat
e2e\run-keep-open.bat
```

On macOS or Linux:

```bash
./e2e/run-complete.sh
./e2e/run-keep-open.sh
```

Each wrapper is a one-line call to Docker, so this works too if you prefer it explicit:

```bat
docker compose -f e2e\docker-compose.e2e.yaml run --rm --build e2e
docker compose -f e2e\docker-compose.e2e.yaml run --rm --build e2e --keep-open
```

A passing run ends with `END-TO-END TEST PASSED` and exit code `0`. Any failure prints the offending request and response and exits `1`.

Leaving a transfer open with `run-keep-open` is harmless: `run-complete` negotiates its own agreement each time and does not touch it.

## Preconditions

The deployment must already be up and onboarded — that is, `deploy-mini.sh` has run: agents started, wallets linked, participants registered with the authority, consumer authenticated with the provider, and the catalog populated.

The test checks this before doing anything and names the problem if not, rather than failing later with an opaque `502`.

## What it verifies

| Phase        | Steps                                                                                                                   |
| ------------ | ----------------------------------------------------------------------------------------------------------------------- |
| Discovery    | Participant DIDs, consumer↔provider authentication, DSP callback address, catalog request                                 |
| Negotiation  | `REQUESTED → OFFERED → REQUESTED → OFFERED → ACCEPTED → AGREED → VERIFIED → FINALIZED` → agreement id                     |
| Transfer     | `REQUESTED → STARTED` → dataplane address                                                                                 |
| Data         | `GET` through the dataplane proxy, asserting the Provider injected the ArcGIS token                                       |
| Lifecycle    | `SUSPENDED → STARTED → COMPLETED`                                                                                         |

The state reached is asserted at every step, so a call that returns `200` with an embedded DSP rejection still fails the test.

It negotiates **Red de ferrocarriles de España – Estaciones**, the dataset whose connector points at the ESRILab ArcGIS server. That choice is what makes the data check meaningful: an anonymous caller gets the same `200` from that endpoint with an empty service list, so a populated one is what proves the token was injected server-side and never exposed.

If the data step fails with ArcGIS code `499`, the token baked into the connector instances has expired — re-run `scripts/ingest-arcgis-token.sh`.

## Options

Arguments after the wrapper are forwarded to the test:

```bat
e2e\run-complete.bat --list-datasets    REM show the catalog and exit
e2e\run-complete.bat -v                 REM dump every DSP request and response
e2e\run-complete.bat --no-data-pull     REM skip the dataplane fetch
e2e\run-complete.bat --no-suspend       REM skip the suspend/resume leg
```

## Pointing it at another host

The container reaches the agents over the host's published ports, which the compose file sets via `host.docker.internal`. Override them for a remote deployment:

```bat
docker compose -f e2e\docker-compose.e2e.yaml run --rm ^
  -e CONSUMER_URL=http://10.0.0.5:1100 ^
  -e PROVIDER_URL=http://10.0.0.5:1200 ^
  e2e
```

`DOCKER_CONSUMER_URL` is separate on purpose: it is the callback address the **provider container** uses to reach the consumer, so it stays container-side even when the other two change.

## Running without Docker

`end-to-end-test.py` is a standalone script that needs only `httpx`, and defaults to `127.0.0.1` for both agents:

```bash
./e2e/end-to-end-test.py          # with uv, dependencies resolve automatically
```
