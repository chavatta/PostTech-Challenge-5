#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 07 - Etapa 7: evidências FinOps.
#   tags     -> inventário de recursos por tag (Project/Environment/CostCenter)
#   cost     -> custo real por tag no Cost Explorer (pode ser negado no Academy; usa forecast do doc)
#   usage    -> uso real de CPU/mem por pod x requests (base do rightsizing)
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"; REGION=${AWS_DEFAULT_REGION:-us-east-1}
case "${1:-tags}" in
  tags)
    step "Recursos por CostCenter=NGO-Core" "prova de tagging 100% via IaC"
    aws resourcegroupstaggingapi get-resources --region $REGION --tag-filters Key=CostCenter,Values=NGO-Core \
      --query 'ResourceTagMappingList[].{arn:ResourceARN}' --output text | awk -F: '{print $3}' | sort | uniq -c | sort -rn
    step "Recursos SEM a tag Project (deveria ser zero)" "auditoria de conformidade"
    aws resourcegroupstaggingapi get-resources --region $REGION --resource-type-filters ec2 eks rds sqs dynamodb s3 ecr \
      --query 'ResourceTagMappingList[?!contains(Tags[].Key, `Project`)].ResourceARN' --output text | tr '\t' '\n' | grep -v '^$' || ok "nenhum" ;;
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
