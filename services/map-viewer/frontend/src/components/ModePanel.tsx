import { useState } from "react";
import { cn } from "../lib/utils";

export type RuntimeMode = "direct" | "eunomia-consumer";

interface Props {
  mode: RuntimeMode;
  connected: boolean;
  onModeChange: (mode: RuntimeMode) => void;
  onConnect: (url: string) => void;
}

export function ModePanel({ mode, connected, onModeChange, onConnect }: Props) {
  const [inputUrl, setInputUrl] = useState("");

  function handleConnect() {
    const url = inputUrl.trim();
    if (url) onConnect(url);
  }

  return (
    <div className="space-y-2">
      <div className="flex rounded-md border border-border overflow-hidden text-[11px] font-semibold">
        <button
          onClick={() => onModeChange("direct")}
          className={cn(
            "flex-1 py-1.5 transition-colors",
            mode === "direct"
              ? "bg-primary text-primary-foreground"
              : "text-muted-foreground hover:bg-muted",
          )}
        >
          DIRECT
        </button>
        <button
          onClick={() => onModeChange("eunomia-consumer")}
          className={cn(
            "flex-1 py-1.5 border-l border-border transition-colors",
            mode === "eunomia-consumer"
              ? "bg-primary text-primary-foreground"
              : "text-muted-foreground hover:bg-muted",
          )}
        >
          EUNOMIA
        </button>
      </div>

      {mode === "direct" && (
        <p className="text-[10px] text-muted-foreground leading-relaxed">
          Token gestionado por FastAPI · acceso directo a ESRILab.
        </p>
      )}

      {mode === "eunomia-consumer" && (
        <div className="space-y-1.5">
          <p className="text-[10px] text-muted-foreground leading-relaxed">
            Token gestionado por el provider Eunomia · requiere un proxy
            compatible con el API de Eunomia Consumer.
          </p>
          <input
            type="url"
            value={inputUrl}
            onChange={(e) => setInputUrl(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && handleConnect()}
            placeholder="https://consumer-proxy/arcgis"
            className="w-full text-[11px] rounded-md border border-input bg-background px-2.5 py-1.5 placeholder:text-muted-foreground/50 focus:outline-none focus:ring-1 focus:ring-ring"
          />
          <div className="flex items-center gap-2">
            <button
              onClick={handleConnect}
              disabled={!inputUrl.trim()}
              className="flex-1 rounded-md bg-primary text-primary-foreground text-[11px] font-semibold py-1.5 disabled:opacity-40 hover:bg-primary/90 transition-colors"
            >
              Conectar
            </button>
            {connected && (
              <span className="flex items-center gap-1 text-[10px] text-green-700 font-medium shrink-0">
                <span className="h-1.5 w-1.5 rounded-full bg-green-500 inline-block" />
                Conectado
              </span>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
