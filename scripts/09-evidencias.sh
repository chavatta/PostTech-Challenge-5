#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 09 - Coleta evidências textuais para o relatório em evidencias/<data>/ (prints ficam por sua conta).
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"; OUT="evidencias/$(date +%Y%m%d-%H%M)"; mkdir -p "$OUT"
step "Apontando para o site primário (workspace terraform + contexto kubectl)" \
     "a Etapa 8 termina com '02-terraform-apply.sh dr', que deixa workspace e kubectl no DR; as evidências são do primário"
use_site primary
ok "workspace $(terraform -chdir=terraform workspace show), kubectl -> $(kubectl config current-context) ($REGION)"
step "Coletando evidências em $OUT" "anexar ao relatório PDF"
{ cd terraform && terraform output; cd ..; } > "$OUT/terraform-outputs.txt" 2>&1
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=SolidaryTech --query 'ResourceTagMappingList[].[ResourceARN,Tags]' --output json > "$OUT/tags.json" 2>&1
kubectl get nodes -o wide > "$OUT/nodes.txt"
kubectl -n argocd get applications > "$OUT/argocd-apps.txt"
kubectl -n solidarytech get all,hpa,pdb,netpol,ingress -o wide > "$OUT/solidarytech-resources.txt"
kubectl -n solidarytech get deploy -o yaml | grep -A4 "resources:" > "$OUT/rightsizing-requests-limits.txt"
kubectl -n solidarytech top pods --containers > "$OUT/kubectl-top.txt" 2>&1
kubectl -n monitoring get prometheusrule donation-service-slo -o yaml > "$OUT/slo-rules.yaml"
velero backup get > "$OUT/velero-backups.txt" 2>&1 || true
velero schedule get > "$OUT/velero-schedules.txt" 2>&1 || true
gh run list --workflow ci.yml --limit 5 > "$OUT/ci-runs.txt"
ok "pronto: ls $OUT"
