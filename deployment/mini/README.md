# Mini Deployment

This folder contains the "mini" deployment approach for the Rainbow framework, using Docker Compose files.

## Requirements

- Docker
- Docker Compose

## Wallet: Fafnir

Each role (authority, provider, consumer) runs its own **Fafnir** wallet as part of its
own compose file — there is no external wallet to start beforehand. Every stack brings up:

1. `*-fafnir-setup` — one-shot job that runs the wallet migrations against the role's Postgres.
2. `*-fafnir-wallet` — the wallet itself, listening on `7001` inside the compose network
   (not published to the host) and gated by a `/readiness` healthcheck.

The agent (`ds-agent`) and Heimdall only start once their wallet reports healthy; the wallet
address is configured in `static/config/<role>/mini/*.yaml` under `wallet_config`.

## Deploying

Bring the authority up first, then the participants:

```bash
docker compose -f docker-compose.mini.heimdall.yaml up -d
docker compose -f docker-compose.mini.provider.yaml up -d provider
docker compose -f docker-compose.mini.consumer.yaml up -d
```

The provider file also carries the one-shot `metadata-ingestion` service, which requires an
ArcGIS token in `API_VALUE` (see `scripts/ingest-arcgis-token.sh`). Use `up -d provider` to
start the connector without it, or `scripts/ingest.sh` to run the ingestion from the host.

## Onboarding

Once the three stacks are up, link the wallets, register both participants with the authority
and complete the consumer↔provider handshake:

```bash
./scripts/mini-onboarding.sh
```

## Entity URLs (Local Access)

- **Heimdall**: [http://localhost:1500/admin/home](http://localhost:1500/admin/home)
- **Consumer**: [http://localhost:1100/admin/login](http://localhost:1100/admin/login)
- **Provider**: [http://localhost:1200/admin/login](http://localhost:1200/admin/login)
- **Map viewer**: [http://localhost:8000](http://localhost:8000) (`docker-compose.mini.map-viewer.yaml`)

> [!NOTE]
> Docker publishes these ports on IPv6 as well as IPv4. If a natively built `monolith` or
> `heimdall` is still running on the host, `127.0.0.1:<port>` may reach that process instead
> of the container — stop it before deploying.

## Credentials

### Consumer & Provider web interface

- **User**: `eunomia`
- **Password**: `eunomia`

### Vault secrets

Database and wallet credentials live in `/vault/[role]/secrets/*.example` and are mounted
read-only into the containers.
