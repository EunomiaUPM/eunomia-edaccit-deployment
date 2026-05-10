import type { AppEnv } from '../config/env'

interface TokenCache {
  token: string
  expiresAt: number // epoch ms
}

// Proactively refresh 5 min before the token actually expires.
const REFRESH_MARGIN_MS = 5 * 60 * 1000

let cache: TokenCache | null = null

export async function getToken(env: AppEnv): Promise<string> {
  if (cache && Date.now() < cache.expiresAt - REFRESH_MARGIN_MS) {
    return cache.token
  }
  return env.authMode === 'direct'
    ? fetchDirectToken()
    : fetchEunomiaToken(env)
}

export function getTokenExpiry(): number | null {
  return cache?.expiresAt ?? null
}

export function clearTokenCache(): void {
  cache = null
}

// ---------------------------------------------------------------------------
// Direct mode — token is proxied through FastAPI (/api/token) so that
// ArcGIS credentials never appear in the browser's network traffic.
// ---------------------------------------------------------------------------

async function fetchDirectToken(): Promise<string> {
  const resp = await fetch('/api/token', { method: 'POST' })
  if (!resp.ok) {
    throw new Error(`Token fetch failed: ${resp.status} ${resp.statusText}`)
  }
  const data = (await resp.json()) as { token: string; expires: number }
  cache = { token: data.token, expiresAt: data.expires }
  return data.token
}

// ---------------------------------------------------------------------------
// Eunomia mode — session token issued by the Consumer Eunomia.
// TODO: Endpoint pending implementation in the Eunomia Connector.
//       Expected contract: POST {VITE_EUNOMIA_CONSUMER_URL}/auth/session
//       Response: { sessionToken: string }
// ---------------------------------------------------------------------------

async function fetchEunomiaToken(env: AppEnv): Promise<string> {
  if (!env.eunomiaConsumerUrl) {
    throw new Error('VITE_EUNOMIA_CONSUMER_URL is required in eunomia mode')
  }
  const resp = await fetch(`${env.eunomiaConsumerUrl}/auth/session`, {
    method: 'POST',
  })
  if (!resp.ok) {
    throw new Error(`Eunomia session fetch failed: ${resp.status}`)
  }
  const data = (await resp.json()) as { sessionToken: string }
  // Eunomia session tokens don't include an expiry field yet — default to 1 h.
  cache = { token: data.sessionToken, expiresAt: Date.now() + 60 * 60 * 1000 }
  return data.sessionToken
}
