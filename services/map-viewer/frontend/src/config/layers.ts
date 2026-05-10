const BASE_URL = import.meta.env.VITE_ARCGIS_BASE_URL as string

export interface LayerDef {
  id: string
  title: string
  url: string
  description?: string
  visibleByDefault: boolean
}

// Add layers here as they become available in the ESRILab portal.
// Only id, title, url, and visibleByDefault are required.
export const LAYER_CATALOG: LayerDef[] = [
  {
    id: 'fuente1-ferroviaria',
    title: 'Infraestructura ferroviaria',
    url: `${BASE_URL}/rest/services/Hosted/Fuente1_Infraestructuraferroviaria/FeatureServer/0`,
    description: 'Red de infraestructura ferroviaria de España (ADIF)',
    visibleByDefault: true,
  },
]
