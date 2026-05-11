import esriConfig from "@arcgis/core/config.js";
import type { AppEnv } from "./env";
import { getToken } from "../services/auth";

esriConfig.assetsPath = "https://js.arcgis.com/4.34/@arcgis/core/assets/";

let _consumerProxyUrl: string | null = null;
let _eunomiaConsumerMode = false;

export function setConsumerProxyUrl(url: string | null): void {
  _consumerProxyUrl = url;
}

export function setEunomiaConsumerMode(enabled: boolean): void {
  _eunomiaConsumerMode = enabled;
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
  // In eunomia-consumer mode, all requests to arcgisBaseUrl must go through
  // the consumer proxy — never through /arcgis-proxy (which injects credentials).
  // If no consumer URL is configured yet, the request is aborted.
  esriConfig.request.interceptors!.push({
    before: (params) => {
      if (!params.url.startsWith(env.arcgisBaseUrl)) return;

      if (_eunomiaConsumerMode && !_consumerProxyUrl) {
        // No proxy connected yet — abort so requests don't fall through to /arcgis-proxy.
        throw new Error("Eunomia consumer proxy not connected");
      }

      if (_consumerProxyUrl) {
        const upstreamUrl = _consumerProxyUrl + params.url.slice(env.arcgisBaseUrl.length);
        params.url = `/eunomia-proxy?target=${encodeURIComponent(upstreamUrl)}`;
      }
    },
  });
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
