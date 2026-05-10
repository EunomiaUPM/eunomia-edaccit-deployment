import esriConfig from '@arcgis/core/config.js'
import type { AppEnv } from './env'
import { getToken } from '../services/auth'

// Use the CDN to serve ArcGIS SDK internal assets (icons, workers, locale files)
// so we don't have to copy node_modules/@arcgis/core/assets into the build output.
// Version must match the installed @arcgis/core package (check package-lock.json).
esriConfig.assetsPath = 'https://js.arcgis.com/4.34/@arcgis/core/assets/'

// Call once at app startup — before any Map or Layer is instantiated.
export function setupArcgis(env: AppEnv): void {
  if (env.authMode === 'direct') {
    // In direct mode the FastAPI proxy at /arcgis-proxy handles token injection
    // and SSL. No client-side interceptor needed.
    return
  }

  // Eunomia mode: inject Bearer session token into requests to the Consumer.
  esriConfig.request.interceptors!.push({
    urls: new RegExp(escapeRegex(env.arcgisBaseUrl)),
    before: async (params) => {
      const token = await getToken(env)
      params.requestOptions.headers = {
        ...(params.requestOptions.headers as Record<string, string>),
        Authorization: `Bearer ${token}`,
      }
    },
  })

  // Rewrite any absolute ESRILab URLs the SDK extracts from response bodies
  // so they continue to pass through the Consumer Eunomia.
  const UPSTREAM_RE = /https:\/\/edaccit\.esrilab\.es\/server/g
  esriConfig.request.interceptors!.push({
    before: (params) => {
      if (UPSTREAM_RE.test(params.url)) {
        params.url = params.url.replace(UPSTREAM_RE, env.arcgisBaseUrl)
      }
      UPSTREAM_RE.lastIndex = 0
    },
  })
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}
