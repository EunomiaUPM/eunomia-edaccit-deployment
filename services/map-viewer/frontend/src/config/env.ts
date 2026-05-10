export interface AppEnv {
  authMode: 'direct' | 'eunomia' | 'eunomia-consumer'
  arcgisBaseUrl: string
  eunomiaConsumerUrl: string | null
}

export function loadEnv(): AppEnv {
  const mode = import.meta.env.VITE_AUTH_MODE
  const baseUrl = import.meta.env.VITE_ARCGIS_BASE_URL

  const missing: string[] = []
  if (!mode) missing.push('VITE_AUTH_MODE')
  if (!baseUrl) missing.push('VITE_ARCGIS_BASE_URL')
  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`)
  }

  if (mode !== 'direct' && mode !== 'eunomia' && mode !== 'eunomia-consumer') {
    throw new Error(`VITE_AUTH_MODE must be "direct", "eunomia", or "eunomia-consumer", got "${mode}"`)
  }

  return {
    authMode: mode,
    arcgisBaseUrl: baseUrl,
    eunomiaConsumerUrl: import.meta.env.VITE_EUNOMIA_CONSUMER_URL ?? null,
  }
}
