import type { LayerDef } from '../config/layers'
import { Checkbox } from './ui/checkbox'
import { cn } from '../lib/utils'

interface Props {
  layers: LayerDef[]
  visibleIds: Set<string>
  onToggle: (id: string) => void
}

export function LayerList({ layers, visibleIds, onToggle }: Props) {
  return (
    <div className="flex-1 overflow-y-auto">
      {layers.map((layer) => {
        const active = visibleIds.has(layer.id)
        return (
          <label
            key={layer.id}
            htmlFor={layer.id}
            className="flex items-start gap-3 px-4 py-3 cursor-pointer hover:bg-accent/60 border-b border-border last:border-0 transition-colors group"
          >
            <Checkbox
              id={layer.id}
              checked={active}
              onCheckedChange={() => onToggle(layer.id)}
              className="mt-0.5 shrink-0"
            />
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-2">
                <span
                  className={cn(
                    'inline-block h-2 w-2 rounded-full shrink-0 transition-colors',
                    active ? 'bg-blue-500' : 'bg-muted-foreground/25',
                  )}
                />
                <span className="text-sm font-medium text-foreground leading-tight">
                  {layer.title}
                </span>
              </div>
              {layer.description && (
                <p className="text-xs text-muted-foreground mt-1 leading-relaxed pl-4">
                  {layer.description}
                </p>
              )}
            </div>
          </label>
        )
      })}
    </div>
  )
}
