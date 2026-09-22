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
     "em contas Academy cuja SCP nega GetBucketObjectLockConfiguration o Terraform roda com manage_velero_bucket=false e o bucket é criado aqui, com as mesmas propriedades do módulo"
if aws s3api head-bucket --bucket "$VELERO_BUCKET" 2>/dev/null; then
  ok "bucket já existe"
else
  if [ "$AWS_REGION" = "us-east-1" ]; then aws s3api create-bucket --bucket "$VELERO_BUCKET" >/dev/null
  else aws s3api create-bucket --bucket "$VELERO_BUCKET" --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null; fi
  ok "bucket criado"
fi
aws s3api put-bucket-tagging --bucket "$VELERO_BUCKET" --tagging 'TagSet=[{Key=Project,Value=SolidaryTech},{Key=Environment,Value=Production},{Key=CostCenter,Value=NGO-Core},{Key=ManagedBy,Value=Script}]'
aws s3api put-bucket-versioning --bucket "$VELERO_BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$VELERO_BUCKET" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$VELERO_BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-lifecycle-configuration --bucket "$VELERO_BUCKET" --lifecycle-configuration '{"Rules":[{"ID":"expire-old-backups","Status":"Enabled","Filter":{},"Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":7}}]}'
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
