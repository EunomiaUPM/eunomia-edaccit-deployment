import { useMemo, useState } from "react";
import { Layers, RefreshCw } from "lucide-react";
import { ArcgisMapView } from "./components/ArcgisMapView";
import { LayerList } from "./components/LayerList";
import { ModePanel, type RuntimeMode } from "./components/ModePanel";
import { setConsumerProxyUrl, setEunomiaConsumerMode } from "./config/arcgis";
import { LAYER_CATALOG } from "./config/layers";
import type { AppEnv } from "./config/env";

interface Props {
  env: AppEnv;
}

export default function App({ env }: Props) {
  const [visibleIds, setVisibleIds] = useState<Set<string>>(
    () =>
      new Set(LAYER_CATALOG.filter((l) => l.visibleByDefault).map((l) => l.id)),
  );

  const initialMode: RuntimeMode =
    env.authMode === "eunomia-consumer" ? "eunomia-consumer" : "direct";
  const [runtimeMode, setRuntimeMode] = useState<RuntimeMode>(() => {
    setEunomiaConsumerMode(initialMode === "eunomia-consumer");
    return initialMode;
  });
  const [activeProxyUrl, setActiveProxyUrl] = useState<string | null>(null);
  const [reloadCount, setReloadCount] = useState(0);

  function handleModeChange(mode: RuntimeMode) {
    setRuntimeMode(mode);
    setEunomiaConsumerMode(mode === "eunomia-consumer");
    if (mode === "direct") {
      setConsumerProxyUrl(null);
      setActiveProxyUrl(null);
    }
  }

  function handleConnect(url: string) {
    setConsumerProxyUrl(url);
    setActiveProxyUrl(url);
  }

  function toggleLayer(id: string) {
    setVisibleIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  const activeLayers = useMemo(
    () => LAYER_CATALOG.filter((l) => visibleIds.has(l.id)),
    [visibleIds],
  );

  return (
    <div className="flex h-screen">
      <aside className="w-72 shrink-0 flex flex-col bg-white border-r border-border shadow-sm overflow-hidden">
        <div className="px-4 pt-5 pb-4 border-b border-border space-y-3">
          <div className="flex items-center gap-2.5">
            <div className="h-8 w-8 rounded-lg bg-primary flex items-center justify-center shrink-0">
              <Layers className="h-4 w-4 text-primary-foreground" />
            </div>
            <div className="min-w-0">
              <p className="text-[10px] font-medium uppercase tracking-widest text-muted-foreground leading-none mb-0.5">
                Eunomia · EDACCIT
              </p>
              <h1 className="text-sm font-semibold text-foreground leading-tight truncate">
                Visor de capas
              </h1>
            </div>
          </div>
          <ModePanel
            mode={runtimeMode}
            connected={!!activeProxyUrl}
            onModeChange={handleModeChange}
            onConnect={handleConnect}
          />
        </div>

        <div className="flex items-center justify-between px-4 py-2.5">
          <span className="text-[10px] font-semibold uppercase tracking-widest text-muted-foreground">
            Capas
          </span>
          <div className="flex items-center gap-2">
            <span className="text-[10px] font-medium text-muted-foreground tabular-nums">
              {activeLayers.length} / {LAYER_CATALOG.length} activas
            </span>
            <button
              onClick={() => setReloadCount((n) => n + 1)}
              title="Recargar datos"
              className="text-muted-foreground hover:text-foreground transition-colors"
            >
              <RefreshCw className="h-3 w-3" />
            </button>
          </div>
        </div>

        <LayerList
          layers={LAYER_CATALOG}
          visibleIds={visibleIds}
          onToggle={toggleLayer}
        />

        <div className="border-t border-border px-4 py-3">
          <p className="text-[10px] text-muted-foreground/70 leading-relaxed">
            Datos bajo licencia EDACCIT
          </p>
        </div>
      </aside>

      <div className="flex-1 relative min-w-0">
        {/* key forces a full MapView remount when the active proxy URL changes */}
        <ArcgisMapView
          key={`${runtimeMode}:${activeProxyUrl ?? ""}:${reloadCount}`}
          activeLayers={runtimeMode === "eunomia-consumer" && !activeProxyUrl ? [] : activeLayers}
        />
      </div>
    </div>
  );
}
