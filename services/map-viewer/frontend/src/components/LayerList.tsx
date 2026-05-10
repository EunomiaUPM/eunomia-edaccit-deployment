import type { LayerDef } from '../config/layers'
import styles from './LayerList.module.css'

interface Props {
  layers: LayerDef[]
  visibleIds: Set<string>
  onToggle: (id: string) => void
}

export function LayerList({ layers, visibleIds, onToggle }: Props) {
  return (
    <div className={styles.list}>
      <p className={styles.heading}>Layers</p>
      {layers.map((layer) => (
        <label key={layer.id} className={styles.item}>
          <input
            type="checkbox"
            checked={visibleIds.has(layer.id)}
            onChange={() => onToggle(layer.id)}
          />
          <span className={styles.name}>{layer.title}</span>
          {layer.description && (
            <span className={styles.desc}>{layer.description}</span>
          )}
        </label>
      ))}
    </div>
  )
}
