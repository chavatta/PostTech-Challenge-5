# Template renderizado por scripts/08-dr-setup.sh (substitui ${VELERO_BUCKET} e ${AWS_REGION}).
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
