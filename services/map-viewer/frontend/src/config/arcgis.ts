import esriConfig from '@arcgis/core/config.js'
import type { AppEnv } from './env'
import { getToken } from '../services/auth'

// Use the CDN to serve ArcGIS SDK internal assets (icons, workers, locale files)
// so we don't have to copy node_modules/@arcgis/core/assets into the build output.
esriConfig.assetsPath = 'https://js.arcgis.com/4.30/@arcgis/core/assets/'

// Call once at app startup — before any Map or Layer is instantiated.
export function setupArcgis(env: AppEnv): void {
  // Interceptor 1: inject auth credentials into every request that targets
  // our configured ArcGIS base URL.
  esriConfig.request.interceptors!.push({
    urls: new RegExp(escapeRegex(env.arcgisBaseUrl)),
    before: async (params) => {
      const token = await getToken(env)
      if (env.authMode === 'direct') {
        // ArcGIS Server / Portal expect the token as a query param.
        params.requestOptions.query = params.requestOptions.query ?? {}
        ;(params.requestOptions.query as Record<string, string>).token = token
      } else {
        // Eunomia Consumer expects a Bearer header.
        params.requestOptions.headers = {
          ...(params.requestOptions.headers as Record<string, string>),
          Authorization: `Bearer ${token}`,
        }
      }
    },
  })

  // Interceptor 2 (eunomia only): the SDK sometimes extracts absolute URLs
  // from response bodies (e.g. related table links, attachment endpoints)
  // and calls them directly. Rewrite any that point at the upstream ArcGIS
  // Server so they continue to pass through the Consumer Eunomia.
  if (env.authMode === 'eunomia') {
    const UPSTREAM_RE = /https:\/\/edaccit\.esrilab\.es\/server/g
    esriConfig.request.interceptors!.push({
      before: (params) => {
        if (UPSTREAM_RE.test(params.url)) {
          params.url = params.url.replace(UPSTREAM_RE, env.arcgisBaseUrl)
        }
        UPSTREAM_RE.lastIndex = 0 // reset after global regex test
      },
    })
  }
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}
