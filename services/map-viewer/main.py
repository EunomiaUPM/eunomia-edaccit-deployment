#!/usr/bin/env python3
"""
Eunomia Map Viewer — FastAPI backend
=====================================
Responsibilities
    POST /api/token  — proxies generateToken to ESRILab; credentials stay server-side
    GET  /api/health — liveness probe
    /*              — serves the pre-built React SPA from frontend/dist/

Run (development):
    uvicorn main:app --reload --port 8000

Run (production, after building the frontend):
    uvicorn main:app --host 0.0.0.0 --port 8000

Environment variables (see .env.example):
    ARCGIS_PORTAL_URL   — ESRILab portal root, e.g. https://edaccit.esrilab.es/portal
    ARCGIS_USERNAME     — service account username
    ARCGIS_PASSWORD     — service account password
    ARCGIS_TOKEN_EXPIRY — token lifetime in minutes (default: 120)
    ARCGIS_VERIFY_SSL   — set to "false" to skip SSL verification (default: true)
    ALLOWED_ORIGINS     — comma-separated CORS origins (default: http://localhost:5173)
"""

import asyncio
import os
import time
from pathlib import Path

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles

load_dotenv()

app = FastAPI(title="Eunomia Map Viewer", docs_url="/api/docs", redoc_url=None)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # proxy must be open; SPA origin is enforced by Vite in dev
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

_verify_ssl = os.getenv("ARCGIS_VERIFY_SSL", "true").lower() != "false"

# ---------------------------------------------------------------------------
# Server-side token cache — one token shared across all proxy requests
# ---------------------------------------------------------------------------

_token_cache: dict = {}
_token_lock = asyncio.Lock()


async def _get_token() -> str:
    """Return a valid ArcGIS token, refreshing proactively 5 min before expiry."""
    async with _token_lock:
        if time.time() < _token_cache.get("expires_at", 0.0) - 300:
            return _token_cache["token"]

        portal_url = os.getenv("ARCGIS_PORTAL_URL")
        username = os.getenv("ARCGIS_USERNAME")
        password = os.getenv("ARCGIS_PASSWORD")
        if not all([portal_url, username, password]):
            raise HTTPException(
                status_code=503,
                detail="ArcGIS credentials not configured (ARCGIS_PORTAL_URL / USERNAME / PASSWORD).",
            )

        expiry_min = os.getenv("ARCGIS_TOKEN_EXPIRY", "120")
        # Use client=referer so the token is URL-bound (not IP-bound).
        # IP-bound tokens (requestip) can fail when the portal and server
        # resolve to different IPs or when running behind NAT.
        referer = os.getenv("ARCGIS_REFERER", "http://localhost:5173")
        async with httpx.AsyncClient(verify=_verify_ssl, timeout=15) as client:
            resp = await client.post(
                f"{portal_url}/sharing/rest/generateToken",
                data={
                    "f": "json",
                    "username": username,
                    "password": password,
                    "client": "referer",
                    "referer": referer,
                    "expiration": expiry_min,
                },
            )

        data = resp.json()
        if "error" in data:
            raise HTTPException(
                status_code=401,
                detail=data["error"].get("message", "Token generation failed"),
            )

        _token_cache["token"] = data["token"]
        _token_cache["expires_at"] = data["expires"] / 1000.0  # ms → s
        return _token_cache["token"]


# ---------------------------------------------------------------------------
# ArcGIS proxy — forwards every SDK request to ESRILab with token injected
# ---------------------------------------------------------------------------

_HOP_BY_HOP = {"content-encoding", "transfer-encoding", "content-length", "connection"}


@app.api_route("/arcgis-proxy/{path:path}", methods=["GET", "POST", "OPTIONS"])
async def arcgis_proxy(path: str, request: Request) -> Response:
    """Transparent proxy for ArcGIS Maps SDK requests.

    Injects the server-side token and bypasses browser SSL restrictions.
    The browser only ever talks to localhost — no direct contact with ESRILab.
    """
    if request.method == "OPTIONS":
        return Response(
            status_code=204,
            headers={
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "*",
            },
        )

    server_url = os.getenv("ARCGIS_SERVER_URL", "").rstrip("/")
    if not server_url:
        raise HTTPException(status_code=503, detail="ARCGIS_SERVER_URL not configured.")

    token = await _get_token()
    # referer-bound tokens require the Referer header to match what was used
    # during generateToken — forward it on every proxied request.
    referer = os.getenv("ARCGIS_REFERER", "http://localhost:5173")

    params = dict(request.query_params)
    params["token"] = token
    params.setdefault("f", "json")

    upstream_url = f"{server_url}/{path}"
    async with httpx.AsyncClient(verify=_verify_ssl, timeout=60) as client:
        if request.method == "GET":
            upstream = await client.get(
                upstream_url, params=params, headers={"Referer": referer}
            )
        else:
            body = await request.body()
            upstream = await client.post(
                upstream_url,
                params=params,
                content=body,
                headers={
                    "content-type": request.headers.get("content-type", ""),
                    "Referer": referer,
                },
            )

    headers = {k: v for k, v in upstream.headers.items() if k.lower() not in _HOP_BY_HOP}
    headers["Access-Control-Allow-Origin"] = "*"

    return Response(
        content=upstream.content,
        status_code=upstream.status_code,
        headers=headers,
        media_type=upstream.headers.get("content-type"),
    )


# ---------------------------------------------------------------------------
# Eunomia consumer proxy — forwards to a dataplane transfer URL (adds CORS)
# ---------------------------------------------------------------------------


@app.api_route("/eunomia-proxy", methods=["GET", "POST", "OPTIONS"])
async def eunomia_proxy(target: str, request: Request) -> Response:
    """Forward a request to an Eunomia consumer dataplane proxy URL.

    The browser cannot reach the consumer directly (CORS), so the frontend
    routes requests here.  `target` must be the full upstream URL including
    path and query string, URL-encoded as a query parameter.
    """
    if request.method == "OPTIONS":
        return Response(
            status_code=204,
            headers={
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "*",
            },
        )

    # When running inside Docker, "localhost" in the browser-supplied URL
    # points to the container itself, not the host.  EUNOMIA_LOCALHOST_ALIAS
    # (e.g. "host.docker.internal") is substituted transparently so the user
    # can still type "localhost:1100" in the GUI.
    localhost_alias = os.getenv("EUNOMIA_LOCALHOST_ALIAS", "")
    if localhost_alias:
        target = target.replace("localhost", localhost_alias, 1)

    # The ArcGIS SDK appends query params (e.g. f=json) after the interceptor
    # rewrites params.url, so they arrive here as extra params alongside 'target'.
    # Forward them to the upstream so the consumer proxy receives them intact.
    extra_params = [(k, v) for k, v in request.query_params.multi_items() if k != "target"]

    async with httpx.AsyncClient(timeout=60) as client:
        if request.method == "GET":
            upstream = await client.get(target, params=extra_params)
        else:
            body = await request.body()
            upstream = await client.post(
                target,
                params=extra_params,
                content=body,
                headers={"content-type": request.headers.get("content-type", "")},
            )

    headers = {k: v for k, v in upstream.headers.items() if k.lower() not in _HOP_BY_HOP}
    headers["Access-Control-Allow-Origin"] = "*"

    return Response(
        content=upstream.content,
        status_code=upstream.status_code,
        headers=headers,
        media_type=upstream.headers.get("content-type"),
    )


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------


@app.get("/api/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/api/token")
async def get_token_endpoint() -> dict:
    """Return the current cached token (useful for debugging)."""
    token = await _get_token()
    return {"token": token, "expires_at": _token_cache.get("expires_at")}


# ---------------------------------------------------------------------------
# Serve the React SPA (production — after `npm run build`)
# ---------------------------------------------------------------------------

_DIST = Path(__file__).parent / "frontend" / "dist"

if _DIST.is_dir():
    # Serve hashed static assets at /assets/* directly
    app.mount("/assets", StaticFiles(directory=_DIST / "assets"), name="assets")

    # Catch-all: everything else returns index.html so React can handle
    # client-side routing if it is added later.
    @app.get("/{path:path}")
    async def spa_fallback(path: str) -> FileResponse:  # noqa: ARG001
        return FileResponse(_DIST / "index.html")
else:

    @app.get("/")
    async def no_build() -> dict:
        return {
            "message": (
                "Frontend not built yet. "
                "Run: cd frontend && npm install && npm run build"
            )
        }
