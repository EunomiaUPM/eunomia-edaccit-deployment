#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
convert_metadata.py — DCAT-AP JSON-LD → Eunomia catalog payloads
=================================================================
Reads every .jsonld file under ./metadata/ and writes two kinds of
Eunomia ingestion payloads to ./catalog-payloads/ (or a custom dir):

  {dataset-id}-dataset.json
      POST to /api/v1/catalog/dataset
      Maps: dct:title → dctTitle

  {dataset-id}-distribution-{n}.json
      POST to /api/v1/catalog/distribution  (one file per dcat:distribution)
      Maps: dct:title → dctTitle, dct:description → dctDescription,
            dcat:accessURL (via dcat:accessService) → dcatAccessService

Placeholders that must be replaced before posting to the API:
  __CATALOG_ID__       — ID returned when the catalog was registered
  __DATA_SERVICE_ID__  — ID of the DataService already registered in Eunomia
  __DATASET_ID__       — ID returned after POSTing the dataset payload

Usage:
    ./convert_metadata.py
    ./convert_metadata.py --output-dir /path/to/output
"""

import argparse
import json
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# JSON-LD helpers
# ---------------------------------------------------------------------------

def get_types(node: dict) -> list[str]:
    # @type can be a bare string or a list; normalise to list for uniform checks
    t = node.get("@type", "")
    return [t] if isinstance(t, str) else list(t)


def get_text(val) -> str | None:
    """Return the plain-string content of a JSON-LD value node.

    Handles the three compact patterns used in these files:
      - plain string          → returned as-is
      - {"@value": "...", ...} → language-tagged literal, first element taken
      - {"@id": "..."}        → named resource, URI returned
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


# ---------------------------------------------------------------------------
# Payload builders
# ---------------------------------------------------------------------------

def dataset_payload(node: dict) -> dict:
    # Eunomia only requires dctTitle and catalogId at dataset-creation time.
    # All richer DCAT-AP metadata (description, keywords, spatial, …) lives
    # in the source JSON-LD and is not forwarded — the catalog record itself
    # is the authoritative source of truth.
    return {
        "dctTitle": get_text(node.get("dct:title")),
        "catalogId": "__CATALOG_ID__",
    }


def distribution_payload(node: dict) -> dict:
    # dctFormats is hardcoded to HTTP_PULL because all distributions in these
    # files expose a pull endpoint (WFS, ArcGIS FeatureServer, CDS API, …).
    # Change to HTTP_PUSH for streaming / subscription distributions.
    payload = {
        "dctTitle": get_text(node.get("dct:title")),
        "dctDescription": get_text(node.get("dct:description")),
        "dcatAccessService": "__DATA_SERVICE_ID__",
        "datasetId": "__DATASET_ID__",
        "dctFormats": "HTTP_PULL",
    }
    # Drop keys whose source field was absent in the JSON-LD to keep payloads
    # clean and avoid sending null values to the API.
    return {k: v for k, v in payload.items() if v is not None}


# ---------------------------------------------------------------------------
# Per-file processing
# ---------------------------------------------------------------------------

def process_file(path: Path, output_dir: Path) -> None:
    data = json.loads(path.read_text(encoding="utf-8"))
    # @graph is a flat list of all typed nodes (Dataset, Distribution,
    # DataService, CatalogRecord, …) sharing a common @context.
    graph: list[dict] = data.get("@graph", [])

    datasets = [n for n in graph if "dcat:Dataset" in get_types(n)]
    # Index distributions by @id so they can be looked up from dcat:distribution
    # references on the dataset node without a second scan of the graph.
    dist_by_id = {
        n["@id"]: n for n in graph if "dcat:Distribution" in get_types(n)
    }

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

        # --- Dataset payload -------------------------------------------------
        ds_out = output_dir / f"{dataset_id}-dataset.json"
        ds_out.write_text(
            json.dumps(dataset_payload(dataset), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        print(f"  {ds_out.name}")

        # --- Distribution payloads (one per dcat:distribution reference) -----
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

            dist_out = output_dir / f"{dataset_id}-distribution-{i}.json"
            dist_out.write_text(
                json.dumps(distribution_payload(dist_node), indent=2, ensure_ascii=False),
                encoding="utf-8",
            )
            print(f"  {dist_out.name}")


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
        default=Path(__file__).parent / "catalog-payloads",
        help="Directory where generated payloads will be written (default: ./catalog-payloads)",
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
