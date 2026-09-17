#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Destrói o ambiente. Rodar SEMPRE ao final da sessão do lab (FinOps: zero custo ocioso).
# Uso: scripts/02-terraform-destroy.sh [primary|dr]
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
SITE="${1:-primary}"
cd "$ROOT_DIR/terraform"
"$ROOT_DIR/scripts/aws-login-check.sh"
terraform workspace select "$SITE" >/dev/null

step "Removendo LoadBalancers criados pelo Kubernetes" \
     "ELBs criados por Services do tipo LoadBalancer não são do Terraform; sem isso o destroy da VPC trava"
if kubectl cluster-info >/dev/null 2>&1; then
  kubectl delete svc --all-namespaces --field-selector spec.type=LoadBalancer --ignore-not-found 2>/dev/null || true
  sleep 30
fi

step "terraform destroy (~15 min)" "desmonta tudo na ordem inversa das dependências"
terraform destroy -input=false -auto-approve -var-file="environments/$SITE.tfvars"
ok "ambiente $SITE destruído"
