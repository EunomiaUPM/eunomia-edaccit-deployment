import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  optimizeDeps: {
    // @arcgis/core uses dynamic imports and workers — skip Vite's pre-bundling
    // to avoid chunking conflicts.
    exclude: ['@arcgis/core'],
  },
  server: {
    // Proxy /api to the FastAPI backend during development so the browser
    // hits a single origin and CORS is never an issue.
    proxy: {
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
      },
    },
  },
})
