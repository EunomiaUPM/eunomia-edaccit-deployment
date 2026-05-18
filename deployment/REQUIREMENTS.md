# Infrastructure Requirements

This document describes the minimum infrastructure needed to deploy the EDACCIT pilot in production.

---

## Machines

Three servers are required. Each runs its own Docker Compose stack independently.

| Machine | Role | Stacks deployed |
|---|---|---|
| **A — Authority** | Dataspace governance, credential issuance, participant registry | Heimdall + Keycloak |
| **B — Provider** | Publishes geospatial datasets; handles DSP negotiation and data transfer | Provider DS-Agent |
| **C — Consumer** | Negotiates access to datasets; renders them in the Map Viewer | Consumer DS-Agent + Map Viewer |

> Machines B and C must reach Machine A over HTTPS. B and C must also reach each other on port 443.

---

## Hardware (per machine)

| Spec | Minimum | Recommended |
|---|---|---|
| vCPU | 2 | 4 |
| RAM | 4 GB | 8 GB |
| Disk | 20 GB | 40 GB |
| OS | Linux (x86-64) | Ubuntu 22.04 LTS |

---

## Software

| Dependency | Version | Notes |
|---|---|---|
| Docker Engine | ≥ 24 | |
| Docker Compose | ≥ 2.20 | Bundled with Docker Desktop |
| `curl`, `jq`, `bash` | any recent | Required for onboarding scripts |

---

## Ports

### Machine A — Authority

| Port | Protocol | Service | Exposed |
|---|---|---|---|
| `443` | HTTPS | oauth2-proxy → Heimdall UI & API | Public |
| `8443` | HTTPS | Keycloak (IdP) | Public |
| `8200` | HTTPS | HashiCorp Vault UI | Internal only |

### Machine B — Provider

| Port | Protocol | Service | Exposed |
|---|---|---|---|
| `443` | HTTPS | Provider DS-Agent (DSP endpoint) | Public |
| `8200` | HTTPS | HashiCorp Vault UI | Internal only |
| `6379` | TCP | Redis | Internal only |

### Machine C — Consumer

| Port | Protocol | Service | Exposed |
|---|---|---|---|
| `443` | HTTPS | Consumer DS-Agent (DSP endpoint) | Public |
| `8000` | HTTP/S | Map Viewer (FastAPI + React) | Public |
| `8200` | HTTPS | HashiCorp Vault UI | Internal only |
| `6379` | TCP | Redis | Internal only |

---

## DNS & TLS

Each machine must have a domain name with a valid TLS certificate in PEM format.

| Machine | Example domain | Certificate files needed |
|---|---|---|
| A | `authority.example.com` | `vault-cert.pem`, `vault-key.pem`, `vault-ca.pem`, `root-ca.pem` |
| B | `provider.example.com` | same as above |
| C | `consumer.example.com` | same as above |

Certificates are placed under `vault/<role>/config/` before first launch.

---

## External dependencies

| Service | Required by | Notes |
|---|---|---|
| **walt.id wallet API** | All agents, Heimdall | Public SaaS — no local deployment needed. Each participant needs its own account. |
| **ESRILab ArcGIS Enterprise** | Provider, Map Viewer | The datasets are hosted at `edaccit.esrilab.es`. Requires valid service-account credentials. |

---

## Deployment order

1. **Machine A** — deploy Heimdall first; agents need to register with it before they can operate.
2. **Machine B** — deploy Provider and ingest catalog metadata (`scripts/ingest.sh`).
3. **Machine C** — deploy Consumer and Map Viewer.
4. **Onboarding** — run `scripts/mini-onboarding.sh` (or the prod equivalent) to register participants and establish mutual trust.

See [`prod/README.md`](prod/README.md) for the full step-by-step deployment guide.
