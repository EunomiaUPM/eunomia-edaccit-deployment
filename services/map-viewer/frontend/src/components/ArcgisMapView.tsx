import { useEffect, useRef, useState } from 'react'
import Map from '@arcgis/core/Map.js'
import MapView from '@arcgis/core/views/MapView.js'
import FeatureLayer from '@arcgis/core/layers/FeatureLayer.js'
import type { LayerDef } from '../config/layers'
import styles from './ArcgisMapView.module.css'

interface Props {
  activeLayers: LayerDef[]
}

export function ArcgisMapView({ activeLayers }: Props) {
  const containerRef = useRef<HTMLDivElement>(null)
  const mapRef = useRef<Map | null>(null)
  const [mapReady, setMapReady] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Create the Map and MapView once on mount. mapReady drives layer sync.
  useEffect(() => {
    if (!containerRef.current) return

    const map = new Map({ basemap: 'streets-vector' })
    const view = new MapView({
      container: containerRef.current,
      map,
      center: [-3.7, 40.4],
      zoom: 6,
    })

    mapRef.current = map
    setMapReady(true)

    return () => {
      view.destroy()
      mapRef.current = null
      setMapReady(false)
    }
  }, [])

  // Sync layers whenever the active set changes (or the map is re-created).
  useEffect(() => {
    const map = mapRef.current
    if (!mapReady || !map) return

    map.layers.removeAll()
    setError(null)

    for (const def of activeLayers) {
      const layer = new FeatureLayer({
        id: def.id,
        url: def.url,
        title: def.title,
        outFields: ['*'],
      })

      layer.when(
        undefined,
        (err: Error) =>
          setError(`Failed to load "${def.title}": ${err.message}`),
      )

      map.layers.add(layer)
    }
  }, [mapReady, activeLayers])

  return (
    <div className={styles.container}>
      <div ref={containerRef} className={styles.map} />
      {error && (
        <div className={styles.errorToast}>
          <span>{error}</span>
          <button onClick={() => setError(null)}>×</button>
        </div>
      )}
    </div>
  )
}
