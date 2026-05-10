import styles from './AuthStatusBadge.module.css'

interface Props {
  mode: 'direct' | 'eunomia'
}

export function AuthStatusBadge({ mode }: Props) {
  return (
    <span className={`${styles.badge} ${mode === 'eunomia' ? styles.eunomia : styles.direct}`}>
      {mode === 'direct' ? 'DIRECT (dev)' : 'EUNOMIA'}
    </span>
  )
}
