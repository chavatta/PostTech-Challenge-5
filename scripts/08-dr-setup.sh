#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 08 - Etapa 8 (parte 1): configura o Velero com o bucket criado pelo Terraform.
# Renderiza gitops/platform/values/velero.yaml a partir do template (bucket real + Schedules) e commita (GitOps).
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"
step "Lendo bucket/região do Terraform (site primário)" "o nome do bucket contém o account id; por isso é renderizado e não fixo"
use_site primary   # workspace primary + AWS_REGION/AWS_DEFAULT_REGION + kubectl no cluster primário (o 02 dr pode ter deixado tudo no DR)
VELERO_BUCKET=$(terraform -chdir=terraform output -raw velero_bucket)
export VELERO_BUCKET
ok "bucket=$VELERO_BUCKET região=$AWS_REGION kubectl=$(kubectl config current-context)"

step "Garantindo que o bucket $VELERO_BUCKET existe com versionamento, criptografia, bloqueio público e lifecycle" \
     "idempotente: se o Terraform já criou, só confirma; se a SCP da conta impediu (ver 02), garante aqui também"
# quando o Terraform gerencia o bucket, não mexe (evita drift); só garante quando é o script que cuida dele
(cd terraform && terraform state list 2>/dev/null | grep -q '^module.registry.aws_s3_bucket.backup') || ensure_velero_bucket "$VELERO_BUCKET"
ok "propriedades do bucket aplicadas (idempotente)"

step "Renderizando os values do Velero (bucket real + Schedules) e commitando" \
     "os Schedules só entram junto com o bucket real: com o placeholder o BSL fica Unavailable e cada execução viraria um backup FailedValidation"
sed "s/\${VELERO_BUCKET}/$VELERO_BUCKET/; s/\${AWS_REGION}/$AWS_REGION/" gitops/platform/values/velero.yaml.tpl > gitops/platform/values/velero.yaml
git_commit_push "dr: velero apontando para $VELERO_BUCKET" gitops/platform/values/velero.yaml
ok "values do Velero no git (origin/main, bucket=$VELERO_BUCKET)"

step "Aguardando o ArgoCD sincronizar o commit e o Velero validar o bucket (BSL Available)" \
     "trocar o bucket só muda o CR BackupStorageLocation, não o Deployment: rollout não prova nada; backup com BSL Unavailable vira FailedValidation"
kubectl -n argocd annotate app velero argocd.argoproj.io/refresh=hard --overwrite >/dev/null
# pronto = BSL com o bucket NOVO (prova que o sync do commit foi aplicado) + Available (o Velero conseguiu acessar o bucket)
#          + app velero Synced e com a operação concluída (Schedules aplicados no mesmo sync)
velero_ready() {
  [ "$(kubectl -n velero get backupstoragelocation default -o jsonpath='{.spec.objectStorage.bucket}/{.status.phase}' 2>/dev/null)" = "$VELERO_BUCKET/Available" ] &&
  [ "$(kubectl -n argocd get app velero -o jsonpath='{.status.sync.status}/{.status.operationState.phase}' 2>/dev/null)" = "Synced/Succeeded" ]
}
for i in $(seq 1 60); do velero_ready && break; printf '\r    aguardando... %ss' "$((i * 5))"; sleep 5; done; echo
kubectl -n argocd get app velero -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,OPERACAO:.status.operationState.phase,REVISOES:.status.sync.revisions'
kubectl -n velero get backupstoragelocation,schedules.velero.io
velero_ready || fail "em 5 min o BSL não ficou Available com o bucket $VELERO_BUCKET ou a app velero não sincronizou (veja acima; kubectl -n argocd describe app velero; kubectl -n velero logs deploy/velero | grep -i 'storage location')"
ok "Velero pronto: BSL Available em s3://$VELERO_BUCKET"

step "Removendo backups FailedValidation da época do bucket placeholder" \
     "foram criados por Schedules com o BSL Unavailable; não têm nada no S3 e só poluiriam 'velero backup get' na evidência"
# delete do CR direto: FailedValidation não tem finalizer nem objeto no bucket, então o backup sync não o traz de volta
FAILED=$(kubectl -n velero get backups.velero.io -o jsonpath='{range .items[?(@.status.phase=="FailedValidation")]}{.metadata.name}{"\n"}{end}')
if [ -n "$FAILED" ]; then
  printf '%s\n' "$FAILED" | xargs kubectl -n velero delete backups.velero.io
  ok "backups FailedValidation removidos"
else
  ok "nenhum backup FailedValidation"
fi
