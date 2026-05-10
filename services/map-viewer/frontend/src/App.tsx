import { useMemo, useState } from "react";
import { Layers } from "lucide-react";
import { ArcgisMapView } from "./components/ArcgisMapView";
import { LayerList } from "./components/LayerList";
import { AuthStatusBadge } from "./components/AuthStatusBadge";
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

  function toggleLayer(id: string) {
    setVisibleIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  // Memoize so ArcgisMapView only re-syncs layers when the set actually changes.
  const activeLayers = useMemo(
    () => LAYER_CATALOG.filter((l) => visibleIds.has(l.id)),
    [visibleIds],
  );

  return (
    <div className="flex h-screen">
      {/* Sidebar */}
      <aside className="w-72 shrink-0 flex flex-col bg-white border-r border-border shadow-sm overflow-hidden">
        {/* Header */}
        <div className="px-4 pt-5 pb-4 border-b border-border">
          <div className="flex items-center gap-2.5 mb-3">
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
          <AuthStatusBadge mode={env.authMode} />
        </div>

        {/* Layer section header */}
        <div className="flex items-center justify-between px-4 py-2.5">
          <span className="text-[10px] font-semibold uppercase tracking-widest text-muted-foreground">
            Capas
          </span>
          <span className="text-[10px] font-medium text-muted-foreground tabular-nums">
            {activeLayers.length} / {LAYER_CATALOG.length} activas
          </span>
        </div>

        {/* Layer list — grows to fill remaining space */}
        <LayerList
          layers={LAYER_CATALOG}
          visibleIds={visibleIds}
          onToggle={toggleLayer}
        />

        {/* Footer */}
        <div className="border-t border-border px-4 py-3">
          <p className="text-[10px] text-muted-foreground/70 leading-relaxed">
            Datos bajo licencia EDACCIT
          </p>
        </div>
      </aside>

      {/* Map */}
      <div className="flex-1 relative min-w-0">
        <ArcgisMapView activeLayers={activeLayers} />
      </div>
    </div>
  );
}
