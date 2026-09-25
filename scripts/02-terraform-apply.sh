#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 02 - Etapa 2: provisiona TODA a infraestrutura via Terraform (nada clicado no console).
# Uso: scripts/02-terraform-apply.sh            (site primário, us-east-1)
#      scripts/02-terraform-apply.sh dr         (site espelho / warm standby)
# Tempo esperado: ~20 min (EKS control plane ~10 min, node group ~5, RDS ~5).
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
SITE="${1:-primary}"
cd "$ROOT_DIR/terraform"
"$ROOT_DIR/scripts/aws-login-check.sh"

step "terraform init" "baixa providers (aws, random) e prepara os módulos"
terraform init -input=false -upgrade >/dev/null && ok "init concluído"

step "terraform workspace select $SITE" \
     "um workspace por site mantém o state do primário separado do state do DR"
terraform workspace select -or-create "$SITE" >/dev/null && ok "workspace: $(terraform workspace show)"

step "terraform fmt -check && terraform validate" "qualidade do IaC: código formatado e sintaticamente válido"
terraform fmt -check -recursive && terraform validate -no-color && ok "código válido"

step "Bucket do Velero: Terraform ou script?" \
     "algumas contas Academy têm SCP que nega s3:GetBucketObjectLockConfiguration e o provider AWS falha ao ler o bucket; o teste decide sozinho, sem ninguém precisar saber disso antes"
export AWS_DEFAULT_REGION=$(awk -F'"' '/^region/{print $2}' "environments/$SITE.tfvars") AWS_REGION=$(awk -F'"' '/^region/{print $2}' "environments/$SITE.tfvars")
VELERO_BUCKET=$(velero_bucket_name "$SITE")
if velero_bucket_tf_allowed "$VELERO_BUCKET"; then
  export TF_VAR_manage_velero_bucket=true; ok "conta permite: bucket $VELERO_BUCKET gerenciado pelo Terraform"
else
  export TF_VAR_manage_velero_bucket=false
  # se uma execução anterior já pôs o bucket no state, tira (só do state; o bucket continua existindo)
  terraform state list 2>/dev/null | grep '^module.registry.aws_s3_bucket' | xargs -n1 terraform state rm >/dev/null 2>&1 || true
  ensure_velero_bucket "$VELERO_BUCKET"
  ok "SCP nega a leitura: bucket $VELERO_BUCKET criado/ajustado via AWS CLI com as mesmas propriedades do módulo"
fi

step "terraform plan" "mostra exatamente o que será criado antes de gastar dinheiro; o plano é salvo e aplicado sem surpresas"
terraform plan -input=false -var-file="environments/$SITE.tfvars" -out="$SITE.tfplan" | tail -25

step "terraform apply (~20 min)" "cria VPC, EKS, node group, RDS, DynamoDB, SQS, ECR e bucket Velero — tudo com tags FinOps"
terraform apply -input=false "$SITE.tfplan"
ok "infraestrutura provisionada"

step "Configurando kubectl" "aponta o kubeconfig para o cluster recém-criado"
eval "$(terraform output -raw kubeconfig_command)" >/dev/null
kubectl get nodes -o wide && ok "nós do EKS prontos"

step "Evidência FinOps: recursos com a tag Project=SolidaryTech" \
     "prova que a política de tags foi aplicada; é o filtro usado no Cost Explorer"
aws resourcegroupstaggingapi get-resources \
  --region "$(terraform output -raw region)" \
  --tag-filters Key=Project,Values=SolidaryTech Key=CostCenter,Values=NGO-Core \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | sed 's/^/    /' | head -40
TOTAL=$(aws resourcegroupstaggingapi get-resources --region "$(terraform output -raw region)" \
  --tag-filters Key=Project,Values=SolidaryTech --query 'length(ResourceTagMappingList)' --output text)
ok "$TOTAL recursos tagueados"

step "Outputs" "endpoints e nomes usados pelas próximas etapas"
terraform output
