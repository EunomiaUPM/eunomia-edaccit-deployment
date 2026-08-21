#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx"]
# ///
"""
end-to-end-test.py — full DSP contract negotiation + transfer against the mini deployment
==========================================================================================
Assumes `./scripts/deploy-mini.sh` already ran: agents up, wallets linked,
participants registered with the authority, consumer authenticated with the
provider, and the catalog populated.

What it exercises, in order:

  Discovery
    1. GET  consumer /api/v1/mates/myself           → consumer DID
    2. GET  provider /api/v1/mates/myself           → provider DID
    3. GET  consumer /.well-known/dspace-version/…  → consumer callback path
    4. POST consumer /dsp/current/catalog/rpc/setup-catalog-request
                                                    → dataset, policy, provider DSP endpoint

  Contract negotiation (the offer echoed back is the one the catalog advertises,
  so the provider's policy engine sees exactly what it published)
    5.  consumer  negotiations/rpc/setup-request-init   REQUESTED
    6.  provider  negotiations/rpc/setup-offer          OFFERED
    7.  consumer  negotiations/rpc/setup-request        REQUESTED
    8.  provider  negotiations/rpc/setup-offer          OFFERED
    9.  consumer  negotiations/rpc/setup-acceptance     ACCEPTED
    10. provider  negotiations/rpc/setup-agreement      AGREED
    11. consumer  negotiations/rpc/setup-verification   VERIFIED
    12. provider  negotiations/rpc/setup-finalization   FINALIZED → agreement id

  Transfer process
    13. consumer  transfers/rpc/setup-request           REQUESTED
    14. provider  transfers/rpc/setup-start             STARTED → dataplane address
    15. GET <dataplane>/rest/services?f=json            real ArcGIS data through the proxy,
                                                        asserting the provider injected the token
    16. consumer  transfers/rpc/setup-suspension        SUSPENDED
    17. consumer  transfers/rpc/setup-start             STARTED
    18. provider  transfers/rpc/setup-completion        COMPLETED

Every step asserts a 2xx and prints the state it reached. The first failure
aborts with the offending request and response body.

By default it negotiates the ESRILab-backed "Red de ferrocarriles" dataset,
the only one in the catalog whose connector points at the pilot's ArcGIS server
and therefore the only one where the injected token can be verified.

Usage:
    ./e2e/end-to-end-test.py
    ./e2e/end-to-end-test.py --dataset ERA5        # pick dataset by title substring
    ./e2e/end-to-end-test.py --list-datasets       # just show what the catalog offers
    ./e2e/end-to-end-test.py --keep-open           # stop before completion, keep the
                                                       # dataplane proxy usable by hand
    ./e2e/end-to-end-test.py --no-suspend          # skip the suspend/resume leg
    ./e2e/end-to-end-test.py --no-data-pull        # skip the proxy fetch
    ./e2e/end-to-end-test.py --data-path '/rest/services/Hosted/\
Fuente1_Infraestructuraferroviaria/FeatureServer/0/query?where=1%3D1&outFields=*&f=geojson'
    ./e2e/end-to-end-test.py -v                    # dump every response body

Environment overrides (same names and defaults as scripts/lib.sh):
    CONSUMER_URL         default http://127.0.0.1:1100
    PROVIDER_URL         default http://127.0.0.1:1200
    DOCKER_CONSUMER_URL  default http://host.docker.internal:1100
"""

import argparse
import json
import os
import sys
from urllib.parse import urlsplit, urlunsplit

import httpx

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
# CONSUMER_URL / PROVIDER_URL are how *we* reach the agents from the host.
# DOCKER_CONSUMER_URL is how the *provider container* reaches the consumer: the
# callback address travels inside the DSP messages, so 127.0.0.1 there would
# point the provider at itself. The provider's own address needs no equivalent
# constant — it arrives already container-resolvable in the catalog response.
CONSUMER_URL = os.environ.get("CONSUMER_URL", "http://127.0.0.1:1100")
PROVIDER_URL = os.environ.get("PROVIDER_URL", "http://127.0.0.1:1200")
DOCKER_CONSUMER_URL = os.environ.get(
    "DOCKER_CONSUMER_URL", "http://host.docker.internal:1100"
)

# Every dataset in the catalog is backed by a different upstream (AEMET, Puertos
# del Estado, Copernicus, CNIG…), and only this one points at the ESRILab ArcGIS
# server the pilot actually demos with. It is the default so a bare run exercises
# the whole chain, token injection included; --dataset overrides it.
_DEFAULT_DATASET = "Red de ferrocarriles"

# Its connector exposes the ArcGIS *server root*, so any REST path can be
# appended to the proxy URL. This one doubles as a token check: an anonymous
# caller gets the same 200 with an empty service list.
_DEFAULT_DATA_PATH = "/rest/services?f=json"

TIMEOUT = httpx.Timeout(60.0)

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
_C = sys.stderr.isatty()


def _paint(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _C else text


def log_step(msg: str) -> None:
    print(_paint("36", f"\n{msg}"), file=sys.stderr)


def log_success(msg: str) -> None:
    print(_paint("32", msg), file=sys.stderr)


def log_info(msg: str) -> None:
    print(_paint("33", msg), file=sys.stderr)


def log_error(msg: str) -> None:
    print(_paint("31", msg), file=sys.stderr)
    sys.exit(1)


VERBOSE = False


def dump(label: str, payload) -> None:
    if VERBOSE:
        print(f"  {label}: {json.dumps(payload, indent=2, ensure_ascii=False)}", file=sys.stderr)


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


def get(client: httpx.Client, url: str) -> dict:
    r = client.get(url)
    if r.status_code >= 300:
        log_error(f"GET {url} -> HTTP {r.status_code}\n{r.text[:800]}")
    return r.json()


def rpc(client: httpx.Client, url: str, payload: dict) -> dict:
    """POST a DSP RPC call and abort on anything that is not 2xx.

    The agents answer 200 with an embedded DSP error for protocol-level
    rejections too, so the state assertions downstream are what actually
    prove the negotiation advanced.
    """
    dump(f"→ {url}", payload)
    r = client.post(url, json=payload)
    if r.status_code >= 300:
        log_error(
            f"POST {url} -> HTTP {r.status_code}\n"
            f"request:\n{json.dumps(payload, indent=2, ensure_ascii=False)}\n"
            f"response:\n{r.text[:1500]}"
        )
    try:
        body = r.json()
    except ValueError:
        log_error(f"POST {url} -> non-JSON response\n{r.text[:800]}")
    dump("←", body)
    return body


def expect_state(body: dict, url: str, *accepted: str) -> str:
    """Assert the negotiation/transfer reached one of the accepted states.

    The state lives under different keys depending on the agent's answer
    shape, so look in the places it is known to appear rather than guessing
    a single path.
    """
    state = (
        _dig(body, "response", "state")
        or _dig(body, "negotiationAgentModel", "state")
        or _dig(body, "transferAgentModel", "state")
        or _dig(body, "state")
    )
    if state is None:
        log_error(
            f"{url}: no state in response\n{json.dumps(body, indent=2, ensure_ascii=False)[:1500]}"
        )
    short = state.rsplit(":", 1)[-1].upper()
    if short not in {s.upper() for s in accepted}:
        log_error(
            f"{url}: expected {' or '.join(accepted)}, got {state}\n"
            f"{json.dumps(body, indent=2, ensure_ascii=False)[:1500]}"
        )
    return short


def _dig(obj, *keys):
    for key in keys:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(key)
    return obj


# ---------------------------------------------------------------------------
# Catalog helpers
# ---------------------------------------------------------------------------


def pick_dataset(datasets: list, wanted: str | None, is_default: bool) -> dict:
    """Choose the dataset to negotiate over.

    Datasets without a policy cannot be negotiated at all, so they are never
    candidates — selecting one would fail several steps later with a much
    less obvious error.
    """
    usable = [d for d in datasets if d.get("hasPolicy")]
    if not usable:
        log_error("The catalog has no dataset with a policy attached. Run the ingestion first.")

    if wanted:
        needle = wanted.casefold()
        matches = [
            d
            for d in usable
            if needle in (d.get("title") or "").casefold() or needle in d.get("@id", "").casefold()
        ]
        if matches:
            return matches[0]
        # An explicit --dataset that matches nothing is a mistake worth stopping
        # for; the built-in default just means this catalog was ingested from
        # different metadata, so fall back rather than refuse to run.
        if not is_default:
            titles = "\n".join(f"  - {d.get('title')}" for d in usable)
            log_error(f"No dataset matches {wanted!r}. Available:\n{titles}")
        log_info(f"No dataset matches the default {wanted!r} — using the first one instead")

    return usable[0]


def offer_from_policy(policy: dict, target_id: str) -> dict:
    """Rebuild the ODRL offer exactly as the catalog advertises it.

    Inventing permissions here (as the tutorial notebook does) makes the test
    measure the agents' tolerance for mismatched offers instead of the real
    negotiation, so the published rules are echoed back verbatim.
    """
    return {
        "@id": policy["@id"],
        "@type": "Offer",
        "target": target_id,
        "permission": policy.get("permission") or [],
        "obligation": policy.get("obligation") or [],
        "prohibition": policy.get("prohibition") or [],
    }


def pull_format(dataset: dict) -> str:
    """Transfer format to request, taken from the dataset's distributions."""
    for dist in dataset.get("distribution") or []:
        fmt = dist.get("formats") or dist.get("format") or dist.get("dctFormats")
        if fmt:
            return fmt
    return "HTTP_PULL"


def rewrite_authority(url: str, reachable_base: str) -> str:
    """Point a container-minted URL at the address this process can actually reach."""
    parsed = urlsplit(url)
    base = urlsplit(reachable_base)
    return urlunsplit((base.scheme, base.netloc, parsed.path, parsed.query, parsed.fragment))


def find_dataplane_url(body: dict) -> str | None:
    """Locate the consumer-side proxy URL in a transfer-start response.

    The data address is nested differently across agent versions, so scan for
    the first endpoint-ish string that points at a dataplane route instead of
    hard-coding a path that a version bump would silently break.
    """
    found: list[str] = []

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if isinstance(value, str) and (
                    "dataplane" in value or key in {"endpoint", "endpointURL", "url"}
                ):
                    found.append(value)
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(body)
    for candidate in found:
        if "dataplane" in candidate:
            return candidate
    return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    global VERBOSE

    parser = argparse.ArgumentParser(
        description="End-to-end DSP negotiation + transfer test against the mini deployment.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--consumer-url", default=CONSUMER_URL)
    parser.add_argument("--provider-url", default=PROVIDER_URL)
    parser.add_argument(
        "--callback-url",
        default=DOCKER_CONSUMER_URL,
        help="Consumer base URL as the provider container sees it",
    )
    parser.add_argument(
        "--dataset",
        help="Substring of the dataset title or id to negotiate "
        f"(default: {_DEFAULT_DATASET!r})",
    )
    parser.add_argument("--list-datasets", action="store_true", help="List the catalog and exit")
    parser.add_argument("--no-suspend", action="store_true", help="Skip the suspend/resume leg")
    parser.add_argument("--no-data-pull", action="store_true", help="Skip the dataplane fetch")
    parser.add_argument(
        "--data-path",
        default=_DEFAULT_DATA_PATH,
        help="REST path appended to the dataplane proxy URL "
        f"(default: {_DEFAULT_DATA_PATH})",
    )
    parser.add_argument(
        "--keep-open",
        action="store_true",
        help="Leave the transfer STARTED instead of completing it",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="Dump every request/response")
    args = parser.parse_args()

    VERBOSE = args.verbose
    consumer = args.consumer_url.rstrip("/")
    provider = args.provider_url.rstrip("/")

    with httpx.Client(timeout=TIMEOUT, headers={"Content-Type": "application/json"}) as client:
        # -------------------------------------------------------------------
        # Step 1 — Discovery
        # -------------------------------------------------------------------
        log_step("Step 1 · Discovering participants")

        consumer_did = get(client, f"{consumer}/api/v1/mates/myself")["participant_id"]
        provider_did = get(client, f"{provider}/api/v1/mates/myself")["participant_id"]
        log_info(f"Consumer DID : {consumer_did[:60]}…")
        log_info(f"Provider DID : {provider_did[:60]}…")

        # The consumer must already hold a mate token for the provider, otherwise
        # every DSP call below comes back as a 502 from the consumer BFF. Failing
        # here names the actual problem instead.
        mates = get(client, f"{consumer}/api/v1/mates/all")
        if not any(
            m.get("participant_id") == provider_did and (m.get("token") or "") for m in mates
        ):
            log_error(
                "The consumer holds no token for the provider.\n"
                "Run ./scripts/mini-onboarding.sh (or deploy-mini.sh) before this test."
            )
        log_success("Consumer is authenticated with the provider")

        version = get(client, f"{consumer}/.well-known/dspace-version/2025-1")
        consumer_callback = args.callback_url.rstrip("/") + version["path"]
        log_info(f"Consumer callback: {consumer_callback}")

        # -------------------------------------------------------------------
        # Step 2 — Catalog request
        # -------------------------------------------------------------------
        log_step("Step 2 · Requesting the provider catalog")

        catalog = rpc(
            client,
            f"{consumer}/dsp/current/catalog/rpc/setup-catalog-request",
            {"associatedAgentPeer": provider_did, "filter": [], "noCache": True},
        )
        response = catalog.get("response") or {}
        datasets = response.get("dataset") or []
        if not datasets:
            log_error("The provider catalog is empty. Run ./scripts/ingest-arcgis-token.sh first.")

        provider_dsp_endpoint = _dig(response, "service", "endpointURL")
        if not provider_dsp_endpoint:
            log_error("The catalog response carries no service endpointURL.")
        log_success(f"Catalog returned {len(datasets)} dataset(s)")

        if args.list_datasets:
            for d in datasets:
                policies = len(d.get("hasPolicy") or [])
                print(f"{d['@id']}\t{policies} policy(ies)\t{d.get('title')}")
            return 0

        dataset = pick_dataset(datasets, args.dataset or _DEFAULT_DATASET, args.dataset is None)
        target_id = dataset["@id"]
        policy = dataset["hasPolicy"][0]
        offer = offer_from_policy(policy, target_id)
        transfer_format = pull_format(dataset)

        log_info(f"Dataset  : {dataset.get('title')}")
        log_info(f"Target   : {target_id}")
        log_info(f"Policy   : {policy['@id']}")
        log_info(f"Provider : {provider_dsp_endpoint}")
        log_info(f"Format   : {transfer_format}")

        # -------------------------------------------------------------------
        # Step 3 — Contract negotiation
        # -------------------------------------------------------------------
        log_step("Step 3 · Contract negotiation")

        url = f"{consumer}/dsp/current/negotiations/rpc/setup-request-init"
        body = rpc(
            client,
            url,
            {
                "associatedAgentPeer": provider_did,
                "providerAddress": provider_dsp_endpoint,
                "callbackAddress": consumer_callback,
                "offer": offer,
            },
        )
        consumer_pid = _dig(body, "response", "consumerPid")
        provider_pid = _dig(body, "response", "providerPid")
        if not consumer_pid or not provider_pid:
            log_error(
                "setup-request-init returned no PIDs\n"
                f"{json.dumps(body, indent=2, ensure_ascii=False)[:1500]}"
            )
        expect_state(body, url, "REQUESTED")
        log_success(f"  1/8 REQUESTED  consumerPid={consumer_pid} providerPid={provider_pid}")

        pids = {"consumerPid": consumer_pid, "providerPid": provider_pid}

        url = f"{provider}/dsp/current/negotiations/rpc/setup-offer"
        body = rpc(client, url, {**pids, "offer": offer})
        expect_state(body, url, "OFFERED")
        log_success("  2/8 OFFERED    (provider)")

        url = f"{consumer}/dsp/current/negotiations/rpc/setup-request"
        body = rpc(client, url, {**pids, "offer": offer})
        expect_state(body, url, "REQUESTED")
        log_success("  3/8 REQUESTED  (consumer)")

        url = f"{provider}/dsp/current/negotiations/rpc/setup-offer"
        body = rpc(client, url, {**pids, "offer": offer})
        expect_state(body, url, "OFFERED")
        log_success("  4/8 OFFERED    (provider, final terms)")

        url = f"{consumer}/dsp/current/negotiations/rpc/setup-acceptance"
        body = rpc(client, url, pids)
        expect_state(body, url, "ACCEPTED")
        log_success("  5/8 ACCEPTED   (consumer)")

        url = f"{provider}/dsp/current/negotiations/rpc/setup-agreement"
        body = rpc(client, url, pids)
        expect_state(body, url, "AGREED")
        log_success("  6/8 AGREED     (provider)")

        url = f"{consumer}/dsp/current/negotiations/rpc/setup-verification"
        body = rpc(client, url, pids)
        expect_state(body, url, "VERIFIED")
        log_success("  7/8 VERIFIED   (consumer)")

        url = f"{provider}/dsp/current/negotiations/rpc/setup-finalization"
        body = rpc(client, url, pids)
        expect_state(body, url, "FINALIZED")
        agreement_id = _dig(body, "negotiationAgentModel", "agreement", "id") or _dig(
            body, "response", "agreement", "@id"
        )
        if not agreement_id:
            log_error(
                "Finalization carried no agreement id\n"
                f"{json.dumps(body, indent=2, ensure_ascii=False)[:1500]}"
            )
        log_success(f"  8/8 FINALIZED  agreement={agreement_id}")

        # -------------------------------------------------------------------
        # Step 4 — Transfer process
        # -------------------------------------------------------------------
        log_step("Step 4 · Transfer process")

        url = f"{consumer}/dsp/current/transfers/rpc/setup-request"
        body = rpc(
            client,
            url,
            {
                "associatedAgentPeer": provider_did,
                "providerAddress": provider_dsp_endpoint,
                "callbackAddress": consumer_callback,
                "agreementId": agreement_id,
                "format": transfer_format,
            },
        )
        t_consumer_pid = _dig(body, "response", "consumerPid")
        t_provider_pid = _dig(body, "response", "providerPid")
        if not t_consumer_pid or not t_provider_pid:
            log_error(
                "Transfer setup-request returned no PIDs\n"
                f"{json.dumps(body, indent=2, ensure_ascii=False)[:1500]}"
            )
        expect_state(body, url, "REQUESTED")
        log_success(
            f"  1/5 REQUESTED  consumerPid={t_consumer_pid} providerPid={t_provider_pid}"
        )

        t_pids = {"consumerPid": t_consumer_pid, "providerPid": t_provider_pid}

        url = f"{provider}/dsp/current/transfers/rpc/setup-start"
        body = rpc(client, url, t_pids)
        expect_state(body, url, "STARTED")
        dataplane_url = find_dataplane_url(body)
        # The provider mints a container-side address; everything shown to the
        # reader is the host-reachable form, so there is only ever one URL on
        # screen for the same endpoint.
        dataplane_public = (
            rewrite_authority(dataplane_url, f"http://localhost:{urlsplit(provider).port or 1200}")
            if dataplane_url
            else None
        )
        log_success("  2/5 STARTED    (provider)")
        if dataplane_public:
            log_info(f"      dataplane: {dataplane_public}")
        else:
            log_info("      no dataplane address in the start response")

        # -------------------------------------------------------------------
        # Step 5 — Pull real data through the proxy
        # -------------------------------------------------------------------
        # This is the only step that proves the agreement is enforced end to
        # end rather than just the DSP state machine turning over. A bare 200
        # proves nothing: the proxy forwards to the ArcGIS server root, which
        # answers 200 with an HTML landing page for a pathless request, and
        # 200 with {"error":{"code":499}} when the token never made it. So the
        # response has to be inspected, not just counted.
        if dataplane_url and not args.no_data_pull:
            log_step("Step 5 · Fetching data through the dataplane proxy")
            # The provider mints this address for container-internal use
            # (host.docker.internal), so its authority is swapped for however we
            # reach the provider. Hardcoding 127.0.0.1 here would break the
            # containerised runner, where that points at the runner itself.
            local_url = rewrite_authority(dataplane_url, provider)
            probe_url = local_url.rstrip("/") + args.data_path
            log_info(f"GET {probe_url}")
            try:
                r = client.get(probe_url)
            except httpx.HTTPError as exc:
                log_error(f"Dataplane request failed: {exc}")
            if r.status_code >= 300:
                log_error(f"Dataplane proxy -> HTTP {r.status_code}\n{r.text[:800]}")

            body_text = r.text
            try:
                data = r.json()
            except ValueError:
                data = None

            # 499 is ArcGIS for "Token Required": the proxy forwarded the call
            # but the provider never injected the API key. This is a real
            # failure of the chain, whatever the upstream is.
            error = data.get("error") if isinstance(data, dict) else None
            if error:
                hint = ""
                if str(error.get("code")) == "499":
                    hint = (
                        "\nCode 499 means the provider did not inject the ArcGIS token — "
                        "the one baked into the connector instances has probably expired. "
                        "Re-run ./scripts/ingest-arcgis-token.sh."
                    )
                log_error(
                    "The upstream returned an error through the proxy: "
                    f"{error.get('code')} {error.get('message')}{hint}"
                )

            log_success(f"Dataplane proxy -> HTTP {r.status_code}, {len(r.content)} bytes")

            # Only the ESRILab-backed dataset answers the default probe with an
            # ArcGIS service listing. Every other dataset in the catalog points
            # at some other upstream (AEMET, Copernicus, THREDDS…), which still
            # proves the proxy forwards — it just cannot prove token injection,
            # so say so instead of failing or claiming more than was checked.
            listing = isinstance(data, dict) and "currentVersion" in data
            if listing and args.data_path == _DEFAULT_DATA_PATH:
                services = data.get("services") or []
                folders = data.get("folders") or []
                if not services and not folders:
                    log_error(
                        "ArcGIS listed no services or folders through the proxy — the "
                        "token was not injected (an anonymous caller sees exactly this)."
                    )
                log_success(
                    f"      ArcGIS {data.get('currentVersion')} · "
                    f"{len(folders)} folder(s), {len(services)} service(s) — token injected"
                )
            else:
                log_info(f"      content-type: {r.headers.get('content-type')}")
                log_info(f"      {body_text[:200].strip()}…")
                if args.data_path == _DEFAULT_DATA_PATH:
                    log_info(
                        "      Upstream is not the ESRILab ArcGIS server, so token "
                        "injection was not asserted. Pass --data-path to probe it."
                    )

        elif args.no_data_pull:
            log_info("Skipping the dataplane fetch (--no-data-pull)")

        # -------------------------------------------------------------------
        # Step 6 — Suspend / resume / complete
        # -------------------------------------------------------------------
        if not args.no_suspend:
            log_step("Step 6 · Suspend and resume")

            url = f"{consumer}/dsp/current/transfers/rpc/setup-suspension"
            body = rpc(
                client,
                url,
                {**t_pids, "code": "SUSPEND", "reason": ["end-to-end-test suspension"]},
            )
            expect_state(body, url, "SUSPENDED")
            log_success("  3/5 SUSPENDED  (consumer)")

            url = f"{consumer}/dsp/current/transfers/rpc/setup-start"
            body = rpc(client, url, t_pids)
            expect_state(body, url, "STARTED")
            log_success("  4/5 STARTED    (consumer, resumed)")
        else:
            log_info("Skipping the suspend/resume leg (--no-suspend)")

        if args.keep_open:
            log_step("Transfer left open (--keep-open)")
            if dataplane_url:
                # Printed as a browser on the host would reach it: the address the
                # provider mints is container-side, and the point of leaving the
                # transfer open is pasting this into the Map Viewer by hand.
                log_success(f"Dataplane proxy URL:\n  {dataplane_public}")
                log_info(
                    "\nPaste it into the Map Viewer at http://localhost:8000 — switch the\n"
                    "sidebar to EUNOMIA and click Conectar. The ArcGIS token is injected\n"
                    "by the Provider and never reaches the browser."
                )
            log_info(
                "\nThe transfer stays STARTED until you complete it from the Consumer UI.\n"
                "Leaving it open is harmless — a full run creates its own agreement."
            )
        else:
            url = f"{provider}/dsp/current/transfers/rpc/setup-completion"
            body = rpc(client, url, t_pids)
            expect_state(body, url, "COMPLETED")
            log_success("  5/5 COMPLETED  (provider)")

    # -----------------------------------------------------------------------
    log_step("=" * 60)
    log_success(
        "END-TO-END TEST PASSED\n"
        f"  Dataset    : {dataset.get('title')}\n"
        f"  Agreement  : {agreement_id}\n"
        f"  Transfer   : {t_consumer_pid} / {t_provider_pid}"
        + (f"\n  Dataplane  : {dataplane_public}" if dataplane_public else "")
    )
    log_step("=" * 60)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log_error("\nInterrupted")
