import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { loadEnv } from './config/env'
import { setupArcgis } from './config/arcgis'
import App from './App'

// Validate env vars at startup and fail fast with a readable message.
let env
try {
  env = loadEnv()
} catch (err) {
  document.getElementById('root')!.innerHTML = `
    <div style="padding:2rem;font-family:monospace;color:#b00;">
      <h2>Configuration error</h2>
      <pre style="margin-top:.5rem;white-space:pre-wrap">${(err as Error).message}</pre>
      <p style="margin-top:1rem">
        Copy <code>frontend/.env.example</code> to
        <code>frontend/.env.development.local</code> and fill in the required values.
      </p>
    </div>
  `
  throw err
}

// Register ArcGIS SDK interceptors once, before any layer is instantiated.
setupArcgis(env)

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App env={env} />
  </StrictMode>,
)
