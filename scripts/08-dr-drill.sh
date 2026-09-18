#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 08 - Etapa 8 (parte 2): TESTE DE DR (o que o enunciado pede: "demonstre o sistema de backup/DR em ação").
#   backup   -> backup sob demanda do namespace solidarytech + lista no S3
#   restore  -> DESTRÓI o namespace solidarytech e restaura do backup; mede o RTO
#   rds      -> snapshot manual do RDS copiado para a região de DR (RPO do banco de doações)
# Requer o CLI do velero: brew install velero
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"; need velero "brew install velero"
case "${1:-}" in
  backup)
    step "Backup sob demanda: velero backup create" "manifests + snapshots EBS do namespace vão para o S3"
    velero backup create "drill-$(date +%Y%m%d-%H%M)" --include-namespaces solidarytech --wait
    velero backup get
    step "Objetos no bucket" "evidência de que o backup saiu do cluster (cross-account/region ready)"
    aws s3 ls "s3://$(cd terraform && terraform output -raw velero_bucket)/backups/" ;;
  restore)
    B=$(velero backup get -o json | python3 -c 'import sys,json;b=[x for x in json.load(sys.stdin)["items"] if x["status"]["phase"]=="Completed"];print(sorted(b,key=lambda x:x["metadata"]["creationTimestamp"])[-1]["metadata"]["name"])')
    step "DESASTRE SIMULADO: kubectl delete namespace solidarytech" "perde-se tudo que está no cluster (não o RDS)"
    START=$(date +%s)
    kubectl -n argocd patch app solidarytech --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null   # pausa o ArgoCD para o teste ser do Velero
    kubectl delete namespace solidarytech --wait=true
    step "Restaurando do backup $B" "velero restore create"
    velero restore create --from-backup "$B" --wait
    kubectl -n solidarytech rollout status deploy/donation-service --timeout=300s
    LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    for i in $(seq 1 30); do curl -fsS -o /dev/null "http://$LB/donations" && break; sleep 5; done
    ok "RTO medido: $(( $(date +%s) - START ))s (anotar em docs/PCN.md)"
    kubectl -n argocd patch app solidarytech --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}' >/dev/null
    ok "ArgoCD reativado" ;;
  rds)
    DR_REGION=${DR_REGION:-us-west-2}; ID=$(cd terraform && terraform output -raw rds_endpoint | cut -d. -f1); SNAP="$ID-dr-$(date +%Y%m%d%H%M)"
    step "Snapshot manual do RDS + cópia para $DR_REGION" "RPO do banco de doações: PITR (5 min) + snapshot cross-region"
    aws rds create-db-snapshot --db-instance-identifier "$ID" --db-snapshot-identifier "$SNAP" --tags Key=Project,Value=SolidaryTech Key=CostCenter,Value=NGO-Core >/dev/null
    aws rds wait db-snapshot-completed --db-snapshot-identifier "$SNAP"
    ACC=$(aws sts get-caller-identity --query Account --output text)
    aws rds copy-db-snapshot --region $DR_REGION --source-db-snapshot-identifier "arn:aws:rds:us-east-1:$ACC:snapshot:$SNAP" \
      --target-db-snapshot-identifier "$SNAP" --copy-tags 2>&1 | head -5 || echo "    (cópia cross-region pode ser negada no Academy; evidência = snapshot local + PITR)"
    aws rds describe-db-snapshots --db-instance-identifier "$ID" --query 'DBSnapshots[].{id:DBSnapshotIdentifier,status:Status}' --output table ;;
  *) echo "uso: $0 {backup|restore|rds}"; exit 1 ;;
esac
