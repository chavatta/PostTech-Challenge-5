# Gerado por scripts/08-dr-setup.sh a partir de velero.yaml.tpl (bucket e região vêm dos outputs do Terraform).
# Sem IRSA no Academy: o Velero usa as credenciais da LabRole do nó (credentials.useSecret=false).
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.11.0
    volumeMounts: [{ mountPath: /target, name: plugins }]
credentials: { useSecret: false }
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: ${VELERO_BUCKET}
      config: { region: ${AWS_REGION} }
  volumeSnapshotLocation:
    - name: default
      provider: aws
      config: { region: ${AWS_REGION} }
  defaultVolumesToFsBackup: false
deployNodeAgent: true
snapshotsEnabled: true
metrics: { enabled: true, serviceMonitor: { enabled: true } }
resources: { requests: { cpu: 100m, memory: 128Mi }, limits: { cpu: 500m, memory: 512Mi } }
# DR opção A: backup periódico do estado do cluster (manifests + volumes EBS) para o S3.
# RPO de configuração do cluster: 1h (hourly). Retenção alinhada ao PCN (docs/PCN.md).
# Ficam aqui, e não no platform-config, para só existirem junto com o bucket real: com o bucket placeholder
# o BSL fica Unavailable e cada execução viraria um Backup FailedValidation. Nome no cluster: velero-<chave>.
schedules:
  solidarytech-hourly:
    schedule: "0 * * * *"
    template:
      includedNamespaces: [solidarytech]
      snapshotVolumes: true
      ttl: 72h0m0s
      storageLocation: default
  platform-daily:
    schedule: "30 3 * * *"
    template:
      includedNamespaces: [solidarytech, monitoring, ingress-nginx, argocd]
      snapshotVolumes: true
      ttl: 720h0m0s        # 30 dias, igual ao lifecycle do bucket
      storageLocation: default
