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

import os
from pathlib import Path

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

load_dotenv()

app = FastAPI(title="Eunomia Map Viewer", docs_url="/api/docs", redoc_url=None)

_origins = [o.strip() for o in os.getenv("ALLOWED_ORIGINS", "http://localhost:5173").split(",")]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

@app.get("/api/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/api/token")
async def get_token() -> dict:
    """Proxy generateToken to ESRILab.

    ArcGIS credentials are read from server-side env vars and never sent to
    the browser. Returns {"token": str, "expires": int (epoch ms)}.
    """
    portal_url = os.getenv("ARCGIS_PORTAL_URL")
    username = os.getenv("ARCGIS_USERNAME")
    password = os.getenv("ARCGIS_PASSWORD")

    if not all([portal_url, username, password]):
        raise HTTPException(
            status_code=503,
            detail=(
                "ArcGIS credentials not configured. "
                "Set ARCGIS_PORTAL_URL, ARCGIS_USERNAME, ARCGIS_PASSWORD."
            ),
        )

    expiration = os.getenv("ARCGIS_TOKEN_EXPIRY", "120")
    verify_ssl = os.getenv("ARCGIS_VERIFY_SSL", "true").lower() != "false"

    async with httpx.AsyncClient(verify=verify_ssl, timeout=15) as client:
        resp = await client.post(
            f"{portal_url}/sharing/rest/generateToken",
            data={
                "f": "json",
                "username": username,
                "password": password,
                # "requestip" is correct for server-to-server calls;
                # use "referer" only when calling from a browser directly.
                "client": "requestip",
                "expiration": expiration,
            },
        )

    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail="Upstream token request failed")

    data = resp.json()
    if "error" in data:
        raise HTTPException(
            status_code=401,
            detail=data["error"].get("message", "Token generation failed"),
        )

    return {"token": data["token"], "expires": data["expires"]}


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
