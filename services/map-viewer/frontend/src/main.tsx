import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { loadEnv } from "./config/env";
import { setupArcgis } from "./config/arcgis";
import App from "./App";
import "./globals.css";

// validate envs or show error message
let env;
try {
  env = loadEnv();
} catch (err) {
  document.getElementById("root")!.innerHTML = `
    <div style="padding:2rem;font-family:monospace;color:#b00;">
      <h2>Configuration error</h2>
      <pre style="margin-top:.5rem;white-space:pre-wrap">${(err as Error).message}</pre>
      <p style="margin-top:1rem">
        Copy <code>frontend/.env.example</code> to
        <code>frontend/.env.development.local</code> and fill in the required values.
      </p>
    </div>
  `;
  throw err;
}

// Arcgis interceptors
setupArcgis(env);

// render
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App env={env} />
  </StrictMode>,
);
