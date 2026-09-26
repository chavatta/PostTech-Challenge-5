#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 07 - Etapa 7: evidências FinOps.
#   tags     -> inventário de recursos por tag (Project/Environment/CostCenter)
#   cost     -> custo real por tag no Cost Explorer (pode ser negado no Academy; usa forecast do doc)
#   usage    -> uso real de CPU/mem por pod x requests (base do rightsizing)
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"; REGION=${AWS_DEFAULT_REGION:-us-east-1}

# O EKS/K8s cria recursos em runtime, fora do Terraform (logo, sem o default_tags do provider), e os marca com
# as próprias tags: nós e launch template gerado (eks:*), SG do cluster (aws:eks:*), ENIs do VPC CNI
# (cluster.k8s.amazonaws.com/*, node.k8s.amazonaws.com/*), volumes de PVC (ebs.csi.aws.com/*, CSIVolumeName,
# kubernetes.io/created-for/*), LBs de Service (kubernetes.io/*) e snapshots do Velero (velero.io/*).
# audit_sem_project lê o inventário (JSON do get-resources na stdin) e lista quem NÃO tem a tag Project:
#   iac -> o que não tem marca do EKS/K8s: saiu do Terraform/scripts e deveria ter Project (esperado: zero)
#   k8s -> o que o EKS/K8s criou, com o dono que as próprias tags indicam (cluster, nodegroup, PVC, backup)
audit_sem_project() {  # $1 = iac | k8s
  python3 -c '
import json, sys
K8S = ("eks:", "aws:eks:", "kubernetes.io/", "ebs.csi.aws.com/", "cluster.k8s.amazonaws.com/",
       "node.k8s.amazonaws.com/", "velero.io/", "CSIVolumeName", "KubernetesCluster")
NOME = ("eks:cluster-name", "aws:eks:cluster-name", "cluster.k8s.amazonaws.com/name", "KubernetesCluster")
linhas = []
for r in json.load(sys.stdin)["ResourceTagMappingList"]:
    # A Tagging API também lista os pods do EKS (arn:aws:eks:...:pod/...), com os labels do pod como "tags".
    # São objetos do Kubernetes, não recursos cobrados da AWS: entrariam na lista "deveria ser zero" como falso positivo.
    if ":pod/" in r["ResourceARN"]:
        continue
    t = {x["Key"]: x["Value"] for x in r.get("Tags", [])}
    k8s = any(k.startswith(K8S) for k in t)
    if "Project" in t or k8s != (sys.argv[1] == "k8s"):  # cada modo só olha a sua metade
        continue
    if sys.argv[1] == "iac":
        linhas.append(r["ResourceARN"]); continue
    cluster = [t[k] for k in NOME if k in t] + [k.split("/", 2)[2] for k in t if k.startswith("kubernetes.io/cluster/")]
    dono = ["cluster=" + cluster[0]] if cluster else []
    for k, rotulo in (("eks:nodegroup-name", "nodegroup"), ("kubernetes.io/service-name", "service"), ("velero.io/backup", "backup")):
        if k in t: dono.append(rotulo + "=" + t[k])
    if "kubernetes.io/created-for/pvc/name" in t:
        dono.append("pvc=" + t.get("kubernetes.io/created-for/pvc/namespace", "?") + "/" + t["kubernetes.io/created-for/pvc/name"])
    arn = r["ResourceARN"].split(":", 5)
    linhas.append(arn[2] + " " + arn[5] + "  " + "  ".join(dono or ["tags=" + ",".join(sorted(t))]))
for l in sorted(linhas): print("    " + l)
' "$1"
}

case "${1:-tags}" in
  tags)
    step "Recursos por CostCenter=NGO-Core" "prova de tagging 100% via IaC"
    aws resourcegroupstaggingapi get-resources --region $REGION --tag-filters Key=CostCenter,Values=NGO-Core \
      --query 'ResourceTagMappingList[].{arn:ResourceARN}' --output text | awk -F: '{print $3}' | sort | uniq -c | sort -rn
    step "Recursos do Terraform/scripts SEM a tag Project (deveria ser zero)" \
         "auditoria de conformidade: o default_tags do provider marca tudo que sai do IaC"
    # Uma chamada só para as duas auditorias, capturada antes: se a API falhar, o set -e para o script em vez de
    # mostrar "nenhum" como evidência. A Tagging API só enxerga recursos com pelo menos uma tag (o IaC sempre põe).
    INV=$(aws resourcegroupstaggingapi get-resources --region "$REGION" --output json \
      --resource-type-filters ec2 eks rds sqs dynamodb s3 ecr elasticloadbalancing)
    OUT=$(audit_sem_project iac <<<"$INV")
    if [ -n "$OUT" ]; then echo "$OUT"; else ok "nenhum"; fi
    step "Criados em runtime pelo EKS/K8s (fora do Terraform)" \
         "nós, ENIs, volumes de PVC, snapshots do Velero e SG do cluster nascem com as tags do EKS/K8s (eks:cluster-name, kubernetes.io/cluster/<nome>...), não com o default_tags; o dono sai dessas tags"
    OUT=$(audit_sem_project k8s <<<"$INV")
    if [ -n "$OUT" ]; then echo "$OUT"; else ok "nenhum"; fi ;;
  cost)
    step "Custo mês corrente agrupado pela tag Project (Cost Explorer)" "se a API for negada no Academy, use docs/FINOPS.md (forecast por lista de preços)"
    aws ce get-cost-and-usage --time-period Start=$(date -v1d +%Y-%m-%d 2>/dev/null || date -d "$(date +%Y-%m-01)" +%Y-%m-%d),End=$(date +%Y-%m-%d) \
      --granularity MONTHLY --metrics UnblendedCost --group-by Type=TAG,Key=Project 2>&1 | head -40 ;;
  usage)
    "$ROOT_DIR/scripts/04-gitops-demo.sh" rightsizing
    step "Uso por nó" "ocupação do cluster: base para decidir tamanho/quantidade de nós"
    kubectl top nodes ;;
  *) echo "uso: $0 {tags|cost|usage}"; exit 1 ;;
esac
