import { Badge } from './ui/badge'

interface Props {
  mode: 'direct' | 'eunomia'
}

export function AuthStatusBadge({ mode }: Props) {
  return (
    <Badge variant={mode === 'eunomia' ? 'success' : 'warning'}>
      {mode === 'direct' ? 'DIRECT (dev)' : 'EUNOMIA'}
    </Badge>
  )
}
