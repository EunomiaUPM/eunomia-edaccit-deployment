#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx"]
# ///
"""
populate_catalog.py — POST Eunomia ingestion payloads to the provider API
=========================================================================
Iterates over every dataset found in the catalog-payloads and
connector-payloads directories and registers each one through the
Eunomia provider API in the following order per dataset:

  1. GET  /api/v1/catalog-agent/catalogs/main       → resolve catalog ID
  2. GET  /api/v1/catalog-agent/data-services/main  → resolve data-service ID
  For each dataset (sorted alphabetically):
  3. POST /api/v1/catalog-agent/datasets             ← {id}-dataset.json
  4. POST /api/v1/catalog-agent/distributions        ← {id}-distribution-{n}.json  (one per file)
  5. POST /api/v1/catalog-agent/odrl-policies        ← {id}-policy.json
  6. POST /api/v1/connector/templates                ← {id}-connector-template.json
  7. POST /api/v1/connector/instances                ← {id}-connector-instance-{n}.json
     Distribution index n is matched to connector-instance index n.

Payload files are loaded from two directories (configurable via CLI):
  --catalog-payloads   default: <repo>/services/metadata-ingestion/catalog-payloads/
  --connector-payloads default: <repo>/services/metadata-ingestion/connector-payloads/

Usage:
    ./populate_catalog.py
    ./populate_catalog.py --provider-url http://my-host:1200
    ./populate_catalog.py --dry-run          # print payloads, do not call the API
"""

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import httpx

# ---------------------------------------------------------------------------
# File-name patterns
# Greedy (.+) matches dataset IDs that contain hyphens; the fixed suffixes
# anchor the match so the rightmost occurrence is always used.
# ---------------------------------------------------------------------------
_DATASET_RE = re.compile(r"^(.+)-dataset\.json$")
_DIST_RE = re.compile(r"^(.+)-distribution-(\d+)\.json$")
_POLICY_RE = re.compile(r"^(.+)-policy\.json$")
_INSTANCE_RE = re.compile(r"^(.+)-connector-instance-(\d+)\.json$")

# Single shared connector template registered once for all datasets.
_SHARED_TEMPLATE_FILE = "connector-template.json"

# Default payload locations relative to this script's directory
_SCRIPT_DIR = Path(__file__).parent
_DEFAULT_CATALOG = _SCRIPT_DIR / "catalog-payloads"
_DEFAULT_CONNECTOR = _SCRIPT_DIR / "connector-payloads"


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class DatasetGroup:
    """All payload files that belong to a single dataset identifier."""

    dataset: Path | None = None
    distributions: dict[int, Path] = field(default_factory=dict)  # n → path
    policy: Path | None = None
    connector_instances: dict[int, Path] = field(default_factory=dict)  # n → path


def group_files(catalog_dir: Path, connector_dir: Path) -> dict[str, DatasetGroup]:
    """Scan both payload directories and group files by dataset identifier."""
    groups: dict[str, DatasetGroup] = {}

    def get_or_create(dataset_id: str) -> DatasetGroup:
        if dataset_id not in groups:
            groups[dataset_id] = DatasetGroup()
        return groups[dataset_id]

    for path in sorted(catalog_dir.glob("*.json")):
        m = _DATASET_RE.match(path.name)
        if m:
            get_or_create(m.group(1)).dataset = path
            continue
        m = _DIST_RE.match(path.name)
        if m:
            get_or_create(m.group(1)).distributions[int(m.group(2))] = path

    for path in sorted(connector_dir.glob("*.json")):
        if path.name == _SHARED_TEMPLATE_FILE:
            continue  # handled separately in main()
        m = _POLICY_RE.match(path.name)
        if m:
            get_or_create(m.group(1)).policy = path
            continue
        m = _INSTANCE_RE.match(path.name)
        if m:
            get_or_create(m.group(1)).connector_instances[int(m.group(2))] = path

    return groups


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------


def api_get(client: httpx.Client, path: str, dry_run: bool) -> dict:
    if dry_run:
        print(f"    [dry-run] GET {path}")
        return {"id": f"__DRY_RUN_ID__{path.rsplit('/', 1)[-1].upper()}__"}
    resp = client.get(path)
    resp.raise_for_status()
    return resp.json()


def api_post(client: httpx.Client, path: str, payload: dict, dry_run: bool) -> dict:
    if dry_run:
        print(f"    [dry-run] POST {path}")
        print(f"    {json.dumps(payload, ensure_ascii=False)}")
        return {"id": "__DRY_RUN_ID__", "name": "__DRY_RUN_NAME__", "version": "0.0"}
    resp = client.post(path, json=payload)
    resp.raise_for_status()
    return resp.json()


# ---------------------------------------------------------------------------
# Per-dataset processing
# ---------------------------------------------------------------------------


def process_dataset(
    dataset_id: str,
    group: DatasetGroup,
    client: httpx.Client,
    catalog_id: str,
    data_service_id: str,
    dry_run: bool,
    tpl_name: str,
    tpl_version: str,
    api_value: str | None,
) -> None:
    print(f"\n{'─' * 60}")
    print(f"  Dataset: {dataset_id}")
    print(f"{'─' * 60}")

    if group.dataset is None:
        print("  [skip] no dataset payload found")
        return

    # --- 1. Dataset ---------------------------------------------------------
    ds_payload = json.loads(group.dataset.read_text(encoding="utf-8"))
    # Inject the runtime catalog ID resolved from the API
    ds_payload["catalogId"] = catalog_id
    ds_resp = api_post(client, "/api/v1/catalog-agent/datasets", ds_payload, dry_run)
    dataset_api_id: str = ds_resp["id"]
    print(f"  dataset_id          = {dataset_api_id}")

    # --- 2. Distributions ---------------------------------------------------
    # Process in index order so connector-instance-n maps to distribution-n
    distribution_ids: dict[int, str] = {}
    for n, dist_path in sorted(group.distributions.items()):
        dist_payload = json.loads(dist_path.read_text(encoding="utf-8"))
        # Inject the resolved IDs that are only known at runtime
        dist_payload["dcatAccessService"] = data_service_id
        dist_payload["datasetId"] = dataset_api_id
        dist_resp = api_post(
            client, "/api/v1/catalog-agent/distributions", dist_payload, dry_run
        )
        distribution_ids[n] = dist_resp["id"]
        print(f"  distribution_id[{n}]  = {distribution_ids[n]}")

    # --- 3. Policy ----------------------------------------------------------
    if group.policy:
        pol_payload = json.loads(group.policy.read_text(encoding="utf-8"))
        pol_payload["entityId"] = dataset_api_id
        pol_resp = api_post(
            client, "/api/v1/catalog-agent/odrl-policies", pol_payload, dry_run
        )
        print(f"  policy_id           = {pol_resp.get('id', 'ok')}")
    else:
        print("  [skip] no policy payload found")

    print(f"  connector_template  = {tpl_name}  v{tpl_version}  (shared)")

    # --- 4. Connector instances ---------------------------------------------
    for n, inst_path in sorted(group.connector_instances.items()):
        inst_payload = json.loads(inst_path.read_text(encoding="utf-8"))
        inst_payload["templateName"] = tpl_name
        inst_payload["templateVersion"] = tpl_version
        if n in distribution_ids:
            inst_payload["distributionId"] = distribution_ids[n]
        else:
            print(f"  [warn] no distribution[{n}] to bind to connector-instance-{n}")
        if api_value is not None:
            inst_payload.setdefault("parameters", {})["API_VALUE"] = api_value
        inst_resp = api_post(
            client, "/api/v1/connector/instances", inst_payload, dry_run
        )
        print(f"  connector_inst[{n}]  = {inst_resp.get('id', 'ok')}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--provider-url",
        default="http://127.0.0.1:1200",
        help="Base URL of the Eunomia provider node (default: http://127.0.0.1:1200)",
    )
    parser.add_argument(
        "--catalog-payloads",
        type=Path,
        default=_DEFAULT_CATALOG,
        help=f"Directory containing *-dataset.json / *-distribution-N.json files (default: {_DEFAULT_CATALOG})",
    )
    parser.add_argument(
        "--connector-payloads",
        type=Path,
        default=_DEFAULT_CONNECTOR,
        help=f"Directory containing *-policy.json / *-connector-*.json files (default: {_DEFAULT_CONNECTOR})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print all resolved payloads without calling the API",
    )
    parser.add_argument(
        "--api-value",
        default=os.environ.get("API_VALUE"),
        metavar="SECRET",
        help="API key secret injected into every connector instance (overrides API_VALUE env var)",
    )
    args = parser.parse_args()

    for d in (args.catalog_payloads, args.connector_payloads):
        if not d.is_dir():
            print(f"Error: directory not found: {d}", file=sys.stderr)
            print(
                "Run convert_metadata.py and convert_connectors.py first.",
                file=sys.stderr,
            )
            sys.exit(1)

    groups = group_files(args.catalog_payloads, args.connector_payloads)
    if not groups:
        print("No payload files found. Nothing to do.", file=sys.stderr)
        sys.exit(1)

    with httpx.Client(base_url=args.provider_url, timeout=30) as client:
        # Resolve the two IDs that are shared across all datasets
        print("==> Fetching main catalog ID...")
        catalog_resp = api_get(
            client, "/api/v1/catalog-agent/catalogs/main", args.dry_run
        )
        catalog_id = catalog_resp["id"]
        print(f"    catalog_id        = {catalog_id}")

        print("==> Fetching main data-service ID...")
        svc_resp = api_get(
            client, "/api/v1/catalog-agent/data-services/main", args.dry_run
        )
        data_service_id = svc_resp["id"]
        print(f"    data_service_id   = {data_service_id}")

        # --- Shared connector template (registered once) --------------------
        shared_tpl_path = args.connector_payloads / _SHARED_TEMPLATE_FILE
        if not shared_tpl_path.exists():
            print(f"Error: shared template not found: {shared_tpl_path}", file=sys.stderr)
            print("Run convert_connectors.py first.", file=sys.stderr)
            sys.exit(1)

        print(f"\n==> Registering shared connector template ({_SHARED_TEMPLATE_FILE})...")
        tpl_payload = json.loads(shared_tpl_path.read_text(encoding="utf-8"))
        tpl_resp = api_post(client, "/api/v1/connector/templates", tpl_payload, args.dry_run)
        tpl_name: str = tpl_resp["name"]
        tpl_version: str = tpl_resp["version"]
        print(f"    template_name     = {tpl_name}  v{tpl_version}")

        for dataset_id, group in sorted(groups.items()):
            process_dataset(
                dataset_id,
                group,
                client,
                catalog_id,
                data_service_id,
                args.dry_run,
                tpl_name,
                tpl_version,
                args.api_value,
            )

    print(f"\n{'=' * 60}")
    print("  Catalog populated successfully.")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()
