import esriConfig from "@arcgis/core/config.js";
import type { AppEnv } from "./env";
import { getToken } from "../services/auth";

esriConfig.assetsPath = "https://js.arcgis.com/4.34/@arcgis/core/assets/";

let _consumerProxyUrl: string | null = null;

export function setConsumerProxyUrl(url: string | null): void {
  _consumerProxyUrl = url;
}

export function setupArcgis(env: AppEnv): void {
  if (env.authMode === "eunomia") {
    // Legacy mode: inject Bearer token + rewrite upstream URLs
    esriConfig.request.interceptors!.push({
      urls: new RegExp(escapeRegex(env.arcgisBaseUrl)),
      before: async (params) => {
        const token = await getToken(env);
        params.requestOptions.headers = {
          ...(params.requestOptions.headers as Record<string, string>),
          Authorization: `Bearer ${token}`,
        };
      },
    });

    const UPSTREAM_RE = /https:\/\/edaccit\.esrilab\.es\/server/g;
    esriConfig.request.interceptors!.push({
      before: (params) => {
        if (UPSTREAM_RE.test(params.url)) {
          params.url = params.url.replace(UPSTREAM_RE, env.arcgisBaseUrl);
        }
        UPSTREAM_RE.lastIndex = 0;
      },
    });
    return;
  }

  // direct / eunomia-consumer: register a proxy-rewrite interceptor.
  // It is a no-op while _consumerProxyUrl is null (DIRECT mode in the GUI).
  // Calling setConsumerProxyUrl(url) activates it without re-registering.
  esriConfig.request.interceptors!.push({
    before: (params) => {
      if (_consumerProxyUrl && params.url.startsWith(env.arcgisBaseUrl)) {
        const upstreamUrl = _consumerProxyUrl + params.url.slice(env.arcgisBaseUrl.length);
        params.url = `/eunomia-proxy?target=${encodeURIComponent(upstreamUrl)}`;
      }
    },
  });
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
