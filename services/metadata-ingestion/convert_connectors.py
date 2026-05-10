#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
convert_connectors.py — DCAT-AP JSON-LD → Eunomia connector payloads
=====================================================================
Reads every .jsonld file under ./metadata/ and writes three kinds of
Eunomia connector payloads to ./connector-payloads/ (or a custom dir):

  {dataset-id}-policy.json
      POST to /api/v1/catalog/policy
      ODRL offer derived from dct:accessRights:
        PUBLIC     → permission: [use] with no constraints
        RESTRICTED → prohibition: [use] (constraints must be filled in manually)

  {dataset-id}-connector-template.json
      POST to /api/v1/connector/template
      Static NO_AUTH / HTTP PULL template. The {{...}} placeholders are
      Eunomia's own template syntax — they are resolved at runtime when a
      connector instance is created, not by this script.

  {dataset-id}-connector-instance-{n}.json
      POST to /api/v1/connector/instance  (one file per dcat:distribution)
      Binds the template to a specific distribution:
        dcat:accessURL  → parameters.ACCESS_URL   (real endpoint URL)
        dcat:mediaType  → ACCESS_HEADERS.Accept   (derived MIME type)

Placeholders that must be replaced before posting to the API:
  __DATASET_ID__        — ID returned after POSTing the dataset payload
  __DISTRIBUTION_ID__   — ID returned after POSTing the distribution payload
  __CONN_PULL_NAME__    — name under which the connector template was registered
  __CONN_PULL_VERSION__ — version of that registered template
  __OWNER_ID__          — participant/organisation identifier in Eunomia

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
    # @type can be a bare string or a list; normalise to list for uniform checks
    t = node.get("@type", "")
    return [t] if isinstance(t, str) else list(t)


def get_text(val) -> str | None:
    """Return the plain-string content of a JSON-LD value node.

    Handles the three compact patterns used in these files:
      - plain string           → returned as-is
      - {"@value": "...", ...} → language-tagged literal, first element taken
      - {"@id": "..."}         → named resource, URI returned
    When the value is a list the first element is used (preferred language).
    """
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
    # Compare only the last URI segment (e.g. "PUBLIC", "RESTRICTED") to avoid
    # false positives: the base URI path contains "publications.europa.eu",
    # which would match a naive substring search for "PUBLIC".
    segment = access_rights.rstrip("/").rsplit("/", 1)[-1].upper()
    return segment == "PUBLIC"


# ---------------------------------------------------------------------------
# Policy payload
# ---------------------------------------------------------------------------

def policy_payload(dataset: dict) -> dict:
    title = get_text(dataset.get("dct:title")) or "Dataset"
    public = is_public(dataset)

    if public:
        # Unrestricted use: no temporal, purpose, or count constraints.
        # Add constraint objects here if finer-grained control is needed.
        permission = [{"action": "use", "constraint": []}]
        prohibition = []
        description = f"Open access policy for '{title}'. Data is publicly available."
    else:
        # Blocked by default: the operator must define the actual permission
        # constraints (purpose, dateTime, count, …) before activating this policy.
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
# Connector template  (static — same structure for all pull datasets)
# ---------------------------------------------------------------------------

# NO_AUTH / HTTP PULL template.  The {{__PARAM__}} syntax is Eunomia's runtime
# template notation: values are substituted when a connector instance is POSTed
# with the matching parameter names in its "parameters" object.
CONNECTOR_TEMPLATE_PULL = {
    "authentication": {"type": "NO_AUTH"},
    "interaction": {
        "mode": "PULL",
        "dataAccess": {
            "protocol": "HTTP",
            "urlTemplate": "{{__ACCESS_URL__}}",
            "method": "{{__ACCESS_METHODS__}}",
            "headers": "{{__ACCESS_HEADERS__}}",
        },
    },
    "parameters": [
        {"paramType": "STRING",           "name": "ACCESS_URL",     "title": "Url",     "required": True},
        {"paramType": "VEC<STRING>",       "name": "ACCESS_METHODS", "title": "Methods", "required": True},
        {"paramType": "MAP<STRING,STRING>","name": "ACCESS_HEADERS", "title": "Headers", "required": True},
    ],
}


# ---------------------------------------------------------------------------
# Connector instance payload
# ---------------------------------------------------------------------------

def derive_accept_header(dist_node: dict) -> str | None:
    """Extract a MIME type string from dcat:mediaType for use as Accept header.

    dcat:mediaType is typically an IANA URI such as:
      https://www.iana.org/assignments/media-types/application/gml+xml
    Only the trailing MIME type segment is kept (e.g. "application/gml+xml").
    If the value is already a plain MIME type it is returned unchanged.
    """
    media_type = get_text(dist_node.get("dcat:mediaType"))
    if not media_type:
        return None
    if "/assignments/media-types/" in media_type:
        return media_type.split("/assignments/media-types/")[-1]
    return media_type


def connector_instance_payload(dist_node: dict) -> dict:
    access_url = get_text(dist_node.get("dcat:accessURL"))
    # Use the distribution description as the human-readable connector note;
    # fall back to the title when no description is present.
    description = (
        get_text(dist_node.get("dct:description"))
        or get_text(dist_node.get("dct:title"))
    )
    accept = derive_accept_header(dist_node)
    # Only include Accept if a MIME type could be derived; an empty headers
    # map is still valid and required by the connector template parameter.
    headers = {"Accept": accept} if accept else {}

    return {
        "templateName": "__CONN_PULL_NAME__",
        "templateVersion": "__CONN_PULL_VERSION__",
        "distributionId": "__DISTRIBUTION_ID__",
        "metadata": {
            "description": description,
            "ownerId": "__OWNER_ID__",
        },
        # dryRun: false — set to true to validate the instance without
        # activating the connector in the Eunomia runtime.
        "dryRun": False,
        "parameters": {
            "ACCESS_URL": access_url or "__ACCESS_URL__",
            "ACCESS_METHODS": ["GET"],
            "ACCESS_HEADERS": headers,
        },
    }


# ---------------------------------------------------------------------------
# Per-file processing
# ---------------------------------------------------------------------------

def process_file(path: Path, output_dir: Path) -> None:
    data = json.loads(path.read_text(encoding="utf-8"))
    # @graph is a flat list of all typed nodes (Dataset, Distribution,
    # DataService, CatalogRecord, …) sharing a common @context.
    graph: list[dict] = data.get("@graph", [])

    datasets = [n for n in graph if "dcat:Dataset" in get_types(n)]
    # Index distributions by @id for O(1) lookup when iterating dataset refs.
    dist_by_id = {n["@id"]: n for n in graph if "dcat:Distribution" in get_types(n)}

    if not datasets:
        print(f"  [skip] no dcat:Dataset found in {path.name}", file=sys.stderr)
        return

    for dataset in datasets:
        # Prefer dct:identifier (stable, human-readable) over the last segment
        # of the @id URI, which can be long or contain encoded characters.
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

        # --- Connector template (NO_AUTH PULL — same structure per dataset) --
        tpl_out = output_dir / f"{dataset_id}-connector-template.json"
        tpl_out.write_text(
            json.dumps(CONNECTOR_TEMPLATE_PULL, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        print(f"  {tpl_out.name}")

        # --- Connector instances (one per dcat:distribution reference) -------
        # The DCAT-AP spec allows a single distribution to be expressed as an
        # object instead of a one-element list; normalise to list.
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

    for path in jsonld_files:
        print(f"\n{path.name}")
        process_file(path, output_dir)

    print(f"\nPayloads written to {output_dir}/")


if __name__ == "__main__":
    main()
