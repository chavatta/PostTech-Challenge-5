#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Destrói o ambiente. Rodar SEMPRE ao final da sessão do lab (FinOps: zero custo ocioso).
# Uso: scripts/02-terraform-destroy.sh [primary|dr]
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
SITE="${1:-primary}"
cd "$ROOT_DIR/terraform"
"$ROOT_DIR/scripts/aws-login-check.sh"

step "Selecionando o site $SITE (workspace terraform + contexto kubectl)" \
     "o destroy e a limpeza dos LoadBalancers têm de mirar o MESMO site; o contexto corrente pode ser o do outro cluster"
# workspace inexistente aborta (use_site dá fail); cluster já apagado (destroy anterior pela metade) é tolerado
if use_site "$SITE"; then ok "workspace $SITE, kubectl -> solidarytech-$SITE ($REGION)"
else ok "workspace $SITE ($REGION); o cluster já não existe, segue só o terraform destroy"; fi

step "Removendo LoadBalancers criados pelo Kubernetes" \
     "ELBs criados por Services do tipo LoadBalancer não são do Terraform; sem isso o destroy da VPC trava"
# --context fixo: sem o cluster deste site, o kubectl não pode cair no contexto corrente (que seria o do outro site)
if kubectl --context "solidarytech-$SITE" --request-timeout=20s cluster-info >/dev/null 2>&1; then
  kubectl --context "solidarytech-$SITE" delete svc --all-namespaces --field-selector spec.type=LoadBalancer --ignore-not-found 2>/dev/null || true
  sleep 30
fi

step "terraform destroy (~15 min)" "desmonta tudo na ordem inversa das dependências"
terraform destroy -input=false -auto-approve -var-file="environments/$SITE.tfvars"
ok "ambiente $SITE destruído"
# devolve workspace e kubectl ao primário (se ele ainda existir) para ninguém herdar o site recém-destruído
[ "$SITE" = primary ] || use_site primary 2>/dev/null || true
