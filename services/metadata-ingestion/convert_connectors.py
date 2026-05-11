#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
convert_connectors.py — DCAT-AP JSON-LD → Eunomia connector payloads
=====================================================================
Reads every .jsonld file under ./metadata/ and writes connector payloads
to ./connector-payloads/ (or a custom dir):

  connector-template.json                          (written once, shared)
      POST to /api/v1/connector/template
      API_KEY / HTTP PULL template. Accepts ACCESS_URL, API_KEY, and API_VALUE
      as runtime parameters. The {{...}} placeholders are Eunomia's template
      syntax — resolved when a connector instance is created.

  {dataset-id}-policy.json
      POST to /api/v1/catalog/policy
      ODRL offer derived from dct:accessRights:
        PUBLIC     → permission: [use] with no constraints
        RESTRICTED → prohibition: [use] (constraints must be filled in manually)

  {dataset-id}-connector-instance-{n}.json
      POST to /api/v1/connector/instance  (one file per dcat:distribution)
      Binds the shared template to a specific distribution:
        dcat:accessURL → parameters.ACCESS_URL

Placeholders that must be replaced before posting to the API:
  __OWNER_ID__   — participant/organisation identifier in Eunomia
  __API_VALUE__  — API key value (token secret); also injectable via --api-value CLI flag
                   or the API_VALUE environment variable in populate_catalog.py

Usage:
    ./convert_connectors.py
    ./convert_connectors.py --output-dir /path/to/output
"""

import argparse
import json
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# JSON-LD helpers  (shared pattern with convert_metadata.py)
# ---------------------------------------------------------------------------

def get_types(node: dict) -> list[str]:
    t = node.get("@type", "")
    return [t] if isinstance(t, str) else list(t)


def get_text(val) -> str | None:
    """Return the plain-string content of a JSON-LD value node."""
    if isinstance(val, str):
        return val
    if isinstance(val, dict):
        if "@value" in val:
            return val["@value"]
        if "@id" in val:
            return val["@id"]
    if isinstance(val, list) and val:
        return get_text(val[0])
    return None


def is_public(node: dict) -> bool:
    access_rights = get_text(node.get("dct:accessRights"))
    if not access_rights:
        return False
    segment = access_rights.rstrip("/").rsplit("/", 1)[-1].upper()
    return segment == "PUBLIC"


# ---------------------------------------------------------------------------
# Policy payload
# ---------------------------------------------------------------------------

def policy_payload(dataset: dict) -> dict:
    title = get_text(dataset.get("dct:title")) or "Dataset"
    public = is_public(dataset)

    if public:
        permission = [{"action": "use", "constraint": []}]
        prohibition = []
        description = f"Open access policy for '{title}'. Data is publicly available."
    else:
        permission = []
        prohibition = [{"action": "use", "constraint": []}]
        description = f"Restricted access policy for '{title}'. Access conditions must be defined."

    return {
        "odrlOffer": {
            "permission": permission,
            "obligation": [],
            "prohibition": prohibition,
        },
        "entityId": "__DATASET_ID__",
        "entityType": "Dataset",
        "description": description,
    }


# ---------------------------------------------------------------------------
# Shared connector template  (API_KEY / HTTP PULL — one file for all datasets)
# ---------------------------------------------------------------------------

# API_KEY query-param auth. The {{__PARAM__}} syntax is Eunomia's runtime
# template notation: values are substituted when a connector instance is POSTed
# with the matching parameter names in its "parameters" object.
#
# API_KEY defaults to "token" (the ArcGIS token query param name), so instances
# only need to supply ACCESS_URL and API_VALUE.
CONNECTOR_TEMPLATE_API_KEY = {
    "authentication": {
        "type": "API_KEY",
        "key": "{{__API_KEY__}}",
        "value": {
            "type": "PLAIN",
            "content": "{{__API_VALUE__}}",
        },
        "location": "QUERY",
    },
    "interaction": {
        "mode": "PULL",
        "dataAccess": {
            "protocol": "HTTP",
            "urlTemplate": "{{__ACCESS_URL__}}",
            "method": ["GET", "POST"],
            "headers": None,
            "bodyTemplate": None,
        },
    },
    "parameters": [
        {"paramType": "STRING", "name": "ACCESS_URL", "title": "Access URL", "required": True},
        {"paramType": "STRING", "name": "API_KEY",    "title": "Api key",    "required": False, "defaultValue": "token"},
        {"paramType": "STRING", "name": "API_VALUE",  "title": "Api value",  "required": True},
    ],
}


# ---------------------------------------------------------------------------
# Connector instance payload
# ---------------------------------------------------------------------------

def connector_instance_payload(dist_node: dict) -> dict:
    access_url = get_text(dist_node.get("dcat:accessURL"))
    description = (
        get_text(dist_node.get("dct:description"))
        or get_text(dist_node.get("dct:title"))
    )

    return {
        "templateName": "__CONN_PULL_NAME__",
        "templateVersion": "__CONN_PULL_VERSION__",
        "distributionId": "__DISTRIBUTION_ID__",
        "metadata": {
            "description": description,
            "ownerId": "__OWNER_ID__",
        },
        "dryRun": False,
        "parameters": {
            "ACCESS_URL": access_url or "__ACCESS_URL__",
            "API_VALUE": "__API_VALUE__",
        },
    }


# ---------------------------------------------------------------------------
# Per-file processing
# ---------------------------------------------------------------------------

def process_file(path: Path, output_dir: Path) -> None:
    data = json.loads(path.read_text(encoding="utf-8"))
    graph: list[dict] = data.get("@graph", [])

    datasets = [n for n in graph if "dcat:Dataset" in get_types(n)]
    dist_by_id = {n["@id"]: n for n in graph if "dcat:Distribution" in get_types(n)}

    if not datasets:
        print(f"  [skip] no dcat:Dataset found in {path.name}", file=sys.stderr)
        return

    for dataset in datasets:
        dataset_id = (
            dataset.get("dct:identifier")
            or dataset["@id"].rsplit(":", 1)[-1]
        )

        # --- Policy ----------------------------------------------------------
        pol_out = output_dir / f"{dataset_id}-policy.json"
        pol_out.write_text(
            json.dumps(policy_payload(dataset), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        print(f"  {pol_out.name}")

        # --- Connector instances (one per dcat:distribution reference) -------
        dist_refs = dataset.get("dcat:distribution", [])
        if isinstance(dist_refs, dict):
            dist_refs = [dist_refs]

        for i, ref in enumerate(dist_refs, start=1):
            dist_id = ref.get("@id") if isinstance(ref, dict) else ref
            dist_node = dist_by_id.get(dist_id)
            if not dist_node:
                print(f"  [warn] distribution {dist_id} not found in graph", file=sys.stderr)
                continue

            inst_out = output_dir / f"{dataset_id}-connector-instance-{i}.json"
            inst_out.write_text(
                json.dumps(connector_instance_payload(dist_node), indent=2, ensure_ascii=False),
                encoding="utf-8",
            )
            print(f"  {inst_out.name}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).parent / "connector-payloads",
        help="Directory where generated payloads will be written (default: ./connector-payloads)",
    )
    args = parser.parse_args()

    metadata_dir = Path(__file__).parent / "metadata"
    output_dir: Path = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    jsonld_files = sorted(metadata_dir.glob("*.jsonld"))
    if not jsonld_files:
        print(f"No .jsonld files found in {metadata_dir}", file=sys.stderr)
        sys.exit(1)

    # --- Shared connector template (written once) ----------------------------
    print("\nShared connector template")
    stale = list(output_dir.glob("*-connector-template.json"))
    for old in stale:
        old.unlink()
        print(f"  [removed] {old.name}")
    tpl_out = output_dir / "connector-template.json"
    tpl_out.write_text(
        json.dumps(CONNECTOR_TEMPLATE_API_KEY, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    print(f"  {tpl_out.name}")

    # --- Per-dataset: policy + connector instances ---------------------------
    for path in jsonld_files:
        print(f"\n{path.name}")
        process_file(path, output_dir)

    print(f"\nPayloads written to {output_dir}/")


if __name__ == "__main__":
    main()
