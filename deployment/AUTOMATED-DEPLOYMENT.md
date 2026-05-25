# Automated Deployment with GitHub Actions

This document explains how the CI/CD pipeline works for the EDACCIT pilot deployment. The workflow automates SSH-based deployment of the Provider (Machine B) and Consumer (Machine C) stacks whenever code is pushed to `main`.

> Machine A (Authority — Heimdall + Keycloak) is not covered by this workflow. It must be deployed manually following [`REQUIREMENTS.md`](REQUIREMENTS.md).

---

## How it works

The workflow file lives at [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml).

```
Push to main  ──►  resolve environment
                        │
               ┌────────┴────────┐
               ▼                 ▼
     deploy-consumer       deploy-provider
     (Machine C via SSH)   (Machine B via SSH)
               │                 │
          git pull           git pull
          docker pull        docker pull
          compose up -d      compose up -d
```

Both machines are deployed **in parallel**. Neither job depends on the other.

Each job connects to its target machine over SSH and runs:

1. `git reset --hard origin/main` — ensures the repo on the machine is in sync.
2. `docker login quay.io` — authenticates to pull the latest image.
3. `docker compose pull` — downloads the updated `ds-agent` image.
4. `docker compose up -d --remove-orphans` — recreates only containers whose image or config changed.

---

## Triggers

| Event | Environment deployed |
|---|---|
| Push to `main` | `prod` (automatic) |
| Manual run (`workflow_dispatch`) | `prod` or `mini` (your choice) |

To trigger a manual run: go to **Actions → Deploy → Run workflow** in the GitHub UI and select the target environment.

---

## Prerequisites

### On each target machine

- Docker Engine ≥ 24 and Docker Compose ≥ 2.20 installed.
- The repository cloned at a fixed path (e.g. `/opt/eunomia`).
- The SSH user has permission to run `docker` and `git` commands.
- Vault certificates and env files already placed (see [`REQUIREMENTS.md`](REQUIREMENTS.md)). These are **not** managed by this workflow — configure them once manually before the first deploy.

### In the GitHub repository

- The two GitHub Environments (`prod` and `mini`) created under **Settings → Environments**.
- All secrets listed below added to each environment.

---

## GitHub Secrets

Add these secrets under **Settings → Environments → `prod`** (and repeat for `mini` if needed).

| Secret | Description |
|---|---|
| `CONSUMER_HOST` | IP address or hostname of Machine C |
| `CONSUMER_USER` | SSH username on Machine C |
| `CONSUMER_SSH_KEY` | Private SSH key for Machine C (PEM format, full contents) |
| `CONSUMER_SSH_PORT` | SSH port on Machine C — omit if 22 |
| `PROVIDER_HOST` | IP address or hostname of Machine B |
| `PROVIDER_USER` | SSH username on Machine B |
| `PROVIDER_SSH_KEY` | Private SSH key for Machine B (PEM format, full contents) |
| `PROVIDER_SSH_PORT` | SSH port on Machine B — omit if 22 |
| `DEPLOY_PATH` | Absolute path to the cloned repo on each machine, e.g. `/opt/eunomia` |
| `QUAY_USER` | quay.io username (to pull `quay.io/eunomia_upm/ds-agent`) |
| `QUAY_PASSWORD` | quay.io password or robot token |

---

## Setting up SSH access

Do this once per target machine before the first automated deploy.

**1. Generate a dedicated key pair** (on your local machine):

```bash
ssh-keygen -t ed25519 -C "github-actions-consumer" -f ~/.ssh/ga_consumer
ssh-keygen -t ed25519 -C "github-actions-provider" -f ~/.ssh/ga_provider
```

**2. Install the public key on each machine:**

```bash
# Machine C (consumer)
ssh-copy-id -i ~/.ssh/ga_consumer.pub <user>@<consumer-host>

# Machine B (provider)
ssh-copy-id -i ~/.ssh/ga_provider.pub <user>@<provider-host>
```

**3. Copy the private key contents into the GitHub secret.**

```bash
# Paste this output into the CONSUMER_SSH_KEY secret
cat ~/.ssh/ga_consumer

# Paste this output into the PROVIDER_SSH_KEY secret
cat ~/.ssh/ga_provider
```

The key must start with `-----BEGIN OPENSSH PRIVATE KEY-----`.

---

## First-time machine setup

The workflow assumes the repository is already cloned on each machine. Run this once:

```bash
# On Machine B (provider)
git clone <repo-url> /opt/eunomia
cd /opt/eunomia
# Place vault certs and env files as described in REQUIREMENTS.md

# On Machine C (consumer)
git clone <repo-url> /opt/eunomia
cd /opt/eunomia
# Place vault certs and env files as described in REQUIREMENTS.md
```

After that, every push to `main` handles updates automatically.

---

## Compose files used per environment

| Environment | Consumer | Provider |
|---|---|---|
| `prod` | `deployment/prod/docker-compose.consumer.yaml` | `deployment/prod/docker-compose.provider.yaml` |
| `mini` | `deployment/mini/docker-compose.mini.consumer.yaml` | `deployment/mini/docker-compose.mini.provider.yaml` |

---

## Deployment order reminder

If deploying from scratch, follow the order in [`REQUIREMENTS.md`](REQUIREMENTS.md):

1. Machine A (Authority) — manual.
2. Machine B (Provider) — via this workflow or manually.
3. Machine C (Consumer) — via this workflow or manually.
4. Run onboarding scripts.

The workflow can safely re-deploy B and C in any order once the authority is up.

---

## Manual fallback

If GitHub Actions is unavailable, deploy manually from each machine:

```bash
# Machine B — provider
cd /opt/eunomia
git pull origin main
docker compose -f deployment/prod/docker-compose.provider.yaml pull
docker compose -f deployment/prod/docker-compose.provider.yaml up -d --remove-orphans

# Machine C — consumer
cd /opt/eunomia
git pull origin main
docker compose -f deployment/prod/docker-compose.consumer.yaml pull
docker compose -f deployment/prod/docker-compose.consumer.yaml up -d --remove-orphans
```
