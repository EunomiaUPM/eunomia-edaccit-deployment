import { useMemo, useState } from "react";
import { ArcgisMapView } from "./components/ArcgisMapView";
import { LayerList } from "./components/LayerList";
import { AuthStatusBadge } from "./components/AuthStatusBadge";
import { LAYER_CATALOG } from "./config/layers";
import type { AppEnv } from "./config/env";
import styles from "./App.module.css";

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
    <div className={styles.shell}>
      <div className={styles.sidebar}>
        <div className={styles.sidebarHeader}>
          <h1 className={styles.title}>Eunomia EDACCIT Viewer</h1>
          <AuthStatusBadge mode={env.authMode} />
        </div>
        <LayerList
          layers={LAYER_CATALOG}
          visibleIds={visibleIds}
          onToggle={toggleLayer}
        />
      </div>
      <div className={styles.mapArea}>
        <ArcgisMapView activeLayers={activeLayers} />
      </div>
    </div>
  );
}
