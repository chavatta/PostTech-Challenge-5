#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 08 - Etapa 8 (parte 1): configura o Velero com o bucket criado pelo Terraform.
# Renderiza gitops/platform/values/velero.yaml a partir do template e commita (GitOps).
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"
step "Lendo bucket/região do Terraform" "o nome do bucket contém o account id; por isso é renderizado e não fixo"
cd terraform; terraform workspace select primary >/dev/null
export VELERO_BUCKET=$(terraform output -raw velero_bucket) AWS_REGION=$(terraform output -raw region); cd "$ROOT_DIR"
export AWS_DEFAULT_REGION="$AWS_REGION"

step "Garantindo que o bucket $VELERO_BUCKET existe com versionamento, criptografia, bloqueio público e lifecycle" \
     "idempotente: se o Terraform já criou, só confirma; se a SCP da conta impediu (ver 02), garante aqui também"
# quando o Terraform gerencia o bucket, não mexe (evita drift); só garante quando é o script que cuida dele
(cd terraform && terraform state list 2>/dev/null | grep -q '^module.registry.aws_s3_bucket.backup') || ensure_velero_bucket "$VELERO_BUCKET"
ok "propriedades do bucket aplicadas (idempotente)"
sed "s/\${VELERO_BUCKET}/$VELERO_BUCKET/; s/\${AWS_REGION}/$AWS_REGION/" gitops/platform/values/velero.yaml.tpl > gitops/platform/values/velero.yaml
git add gitops/platform/values/velero.yaml
git diff --cached --quiet || { git commit -q -m "dr: velero apontando para $VELERO_BUCKET"; git push -q origin main; }
ok "values do Velero commitados (bucket=$VELERO_BUCKET)"

step "Aguardando o ArgoCD instalar/atualizar o Velero" "backup também é GitOps"
kubectl -n argocd annotate app velero argocd.argoproj.io/refresh=hard --overwrite >/dev/null
for i in $(seq 1 30); do kubectl -n velero rollout status deploy/velero --timeout=10s >/dev/null 2>&1 && break; sleep 10; done
kubectl -n velero get backupstoragelocation
ok "Velero pronto"
