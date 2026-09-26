#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 08 - Etapa 8 (parte 2): TESTE DE DR (o que o enunciado pede: "demonstre o sistema de backup/DR em ação").
#   backup   -> backup sob demanda do namespace solidarytech + lista no S3
#   restore  -> DESTRÓI o namespace solidarytech e restaura do backup com o ArgoCD pausado; mede o RTO
#   rds      -> snapshot manual do RDS copiado para a região de DR (RPO do banco de doações)
# Requer o CLI do velero: brew install velero
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"; need velero "brew install velero"
case "${1:-}" in backup|restore|rds) ;; *) echo "uso: $0 {backup|restore|rds}"; exit 1 ;; esac
step "Apontando para o site primário (workspace terraform + contexto kubectl)" \
     "o drill é no primário; '02-terraform-apply.sh dr' pode ter deixado workspace e kubectl no DR"
use_site primary
ok "kubectl -> $(kubectl config current-context) ($AWS_REGION)"
case "$1" in
  backup)
    B="drill-$(date +%Y%m%d-%H%M)"
    step "Backup sob demanda: velero backup create" "manifests + snapshots EBS do namespace vão para o S3"
    velero backup create "$B" --include-namespaces solidarytech --wait
    velero backup get
    # --wait sai com 0 mesmo em FailedValidation/PartiallyFailed: a evidência só vale se o backup completou
    [ "$(kubectl -n velero get backups.velero.io "$B" -o jsonpath='{.status.phase}')" = Completed ] \
      || fail "backup $B não completou (velero backup describe $B --details; BSL Available? rode scripts/08-dr-setup.sh)"
    step "Objetos no bucket" "evidência de que o backup saiu do cluster (cross-account/region ready)"
    aws s3 ls "s3://$(terraform -chdir=terraform output -raw velero_bucket)/backups/" ;;
  restore)
    # kubectl e não `velero backup get -o json`: com um único backup o CLI do velero imprime o objeto solto, sem "items"
    B=$(kubectl -n velero get backups.velero.io -o json | python3 -c 'import sys,json
b=[x for x in json.load(sys.stdin)["items"] if x.get("status",{}).get("phase")=="Completed"]
print(max(b,key=lambda x:x["metadata"]["creationTimestamp"])["metadata"]["name"] if b else "")')
    [ -n "$B" ] || fail "nenhum backup Completed para restaurar: rode antes '$0 backup'"

    step "Pausando o auto-sync do ArgoCD: app root E app solidarytech" \
         "a root tem selfHeal e gerencia a Application solidarytech: pausar só a filha é desfeito em segundos e o ArgoCD recriaria o namespace junto com o Velero"
    ROOT_POLICY=$(kubectl -n argocd get app root -o jsonpath='{.spec.syncPolicy}')
    APP_POLICY=$(kubectl -n argocd get app solidarytech -o jsonpath='{.spec.syncPolicy}')
    [ -n "$ROOT_POLICY" ] && [ -n "$APP_POLICY" ] \
      || fail "auto-sync já estava desligado (drill anterior interrompido?): kubectl apply -f gitops/argocd/root-app.yaml, espere a app solidarytech voltar a ter syncPolicy e rode de novo"
    argocd_resume() {  # devolve exatamente o syncPolicy salvo (= o do git, com retry e syncOptions): filha e depois root
      kubectl -n argocd patch app solidarytech --type merge -p "{\"spec\":{\"syncPolicy\":$APP_POLICY}}" >/dev/null
      kubectl -n argocd patch app root --type merge -p "{\"spec\":{\"syncPolicy\":$ROOT_POLICY}}" >/dev/null
    }
    # se qualquer passo abaixo falhar (ou Ctrl+C), o ArgoCD não fica pausado
    trap 'argocd_resume && printf "    ArgoCD religado (drill interrompido)\n"' EXIT
    kubectl -n argocd patch app root --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null   # a root primeiro: senão ela desfaz o patch da filha
    kubectl -n argocd patch app solidarytech --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null
    kubectl -n argocd get app root solidarytech -o custom-columns='APP:.metadata.name,AUTO-SYNC:.spec.syncPolicy.automated,SYNC:.status.sync.status'
    ok "ArgoCD pausado (AUTO-SYNC <none>): até o fim do restore, nada no namespace é recriado pelo ArgoCD"

    step "DESASTRE SIMULADO: kubectl delete namespace solidarytech" "perde-se tudo que está no cluster (não o RDS)"
    START=$(date +%s)
    kubectl delete namespace solidarytech --wait=true
    R="$B-restore-$(date +%H%M%S)"
    step "Restaurando do backup $B (restore $R)" "só o Velero age: o namespace volta do S3, inclusive os Secrets que não estão no git"
    # --include-namespaces: se o último backup for o diário da plataforma, restaura só o namespace do teste
    velero restore create "$R" --from-backup "$B" --include-namespaces solidarytech --wait
    # como no backup, --wait sai com 0 mesmo em PartiallyFailed
    [ "$(kubectl -n velero get restores.velero.io "$R" -o jsonpath='{.status.phase}')" = Completed ] \
      || fail "restore $R não completou (velero restore describe $R --details)"
    kubectl -n solidarytech rollout status deploy/donation-service --timeout=300s
    LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    for i in $(seq 1 30); do curl -fsS -o /dev/null "http://$LB/donations" && break; sleep 5; done
    curl -fsS -o /dev/null "http://$LB/donations" || fail "a API não respondeu em http://$LB/donations depois do restore"
    ok "RTO medido: $(( $(date +%s) - START ))s (anotar em docs/PCN.md)"

    step "Quem recriou o quê" "cada objeto tem o label velero.io/restore-name=$R: foi o Velero, não o ArgoCD (pausado até agora)"
    kubectl -n solidarytech get deploy,svc,configmap,secret -L velero.io/restore-name

    step "Religando o auto-sync do ArgoCD (solidarytech e root)" \
         "o git volta a mandar; o ArgoCD só corrige o que o restore tiver deixado diferente do git"
    # o trap só sai depois do resume: se um patch falhar aqui, o trap tenta de novo (patch idempotente)
    argocd_resume
    trap - EXIT
    kubectl -n argocd get app root solidarytech -o custom-columns='APP:.metadata.name,AUTO-SYNC:.spec.syncPolicy.automated,SYNC:.status.sync.status'
    ok "ArgoCD reativado" ;;
  rds)
    # região de DR: a mesma do tfvars que sobe o site dr (fonte única); DR_REGION no ambiente sobrescreve
    DR_REGION=${DR_REGION:-$(awk -F'"' '/^region/{print $2}' terraform/environments/dr.tfvars)}
    ID=$(terraform -chdir=terraform output -raw rds_endpoint | cut -d. -f1); SNAP="$ID-dr-$(date +%Y%m%d%H%M)"
    step "Snapshot manual do RDS ($AWS_REGION) + cópia para $DR_REGION" "RPO do banco de doações: PITR (5 min) + snapshot cross-region"
    aws rds create-db-snapshot --db-instance-identifier "$ID" --db-snapshot-identifier "$SNAP" --tags Key=Project,Value=SolidaryTech Key=CostCenter,Value=NGO-Core >/dev/null
    aws rds wait db-snapshot-completed --db-snapshot-identifier "$SNAP"
    ACC=$(aws sts get-caller-identity --query Account --output text)
    # o RDS é criptografado (aws/rds): a cópia entre regiões exige uma chave KMS da região de DESTINO, senão a API recusa.
    # DescribeKey no alias gerenciado pela AWS cria a aws/rds de lá se ainda não existir; sem essa permissão, o RDS resolve o alias
    KMS=$(aws kms describe-key --region "$DR_REGION" --key-id alias/aws/rds --query KeyMetadata.Arn --output text 2>/dev/null) || KMS=alias/aws/rds
    if aws rds copy-db-snapshot --region "$DR_REGION" --source-region "$AWS_REGION" \
         --source-db-snapshot-identifier "arn:aws:rds:$AWS_REGION:$ACC:snapshot:$SNAP" \
         --target-db-snapshot-identifier "$SNAP" --kms-key-id "$KMS" --copy-tags >/dev/null; then
      step "Aguardando a cópia ficar available em $DR_REGION (até 30 min)" \
           "o snapshot só serve de DR quando está completo na outra região: é dele que o site dr restaura o banco (docs/PCN.md)"
      # db-snapshot-available: até 30 min (60 x 30s) e para cedo se a cópia falhar. A 1a cópia cross-region de snapshot
      # criptografado é cheia e pode demorar mais: o timeout não aborta o drill, a cópia segue sozinha na AWS
      aws rds wait db-snapshot-available --region "$DR_REGION" --db-snapshot-identifier "$SNAP" \
        || echo "    (espera encerrada sem 'available': status e progresso reais na tabela abaixo)"
      aws rds describe-db-snapshots --region "$DR_REGION" --db-snapshot-identifier "$SNAP" \
        --query 'DBSnapshots[].{id:DBSnapshotIdentifier,status:Status,progresso:PercentProgress,chave:KmsKeyId}' --output table
      ST=$(aws rds describe-db-snapshots --region "$DR_REGION" --db-snapshot-identifier "$SNAP" --query 'DBSnapshots[0].Status' --output text)
      case "$ST" in
        available) ok "snapshot $SNAP disponível em $DR_REGION" ;;
        failed|deleted|deleting|incompatible-*) fail "cópia $SNAP em $DR_REGION terminou com status '$ST'" ;;
        *) ok "cópia $SNAP em andamento em $DR_REGION ($ST): continua sozinha; confira depois com o describe acima" ;;
      esac
    else
      echo "    (cópia cross-region negada nesta conta, erro acima; evidência = snapshot local + PITR)"
      aws rds describe-db-snapshots --db-snapshot-identifier "$SNAP" --query 'DBSnapshots[].{id:DBSnapshotIdentifier,status:Status}' --output table
    fi ;;
esac
