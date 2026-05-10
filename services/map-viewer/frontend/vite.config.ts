import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig({
  plugins: [tailwindcss(), react()],
  optimizeDeps: {
    // @arcgis/core uses dynamic imports and workers — skip Vite's pre-bundling
    // to avoid chunking conflicts.
    exclude: ['@arcgis/core'],
  },
  server: {
    // Proxy /api to the FastAPI backend during development so the browser
    // hits a single origin and CORS is never an issue.
    proxy: {
      '/api': { target: 'http://localhost:8000', changeOrigin: true },
      '/arcgis-proxy': { target: 'http://localhost:8000', changeOrigin: true },
      '/eunomia-proxy': { target: 'http://localhost:8000', changeOrigin: true },
    },
  },
})
