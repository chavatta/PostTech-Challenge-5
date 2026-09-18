#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Demonstrações de GitOps para o vídeo:
#   selfheal  -> altera réplicas na mão e mostra o ArgoCD revertendo (ninguém mexe no cluster sem git)
#   rollout   -> acompanha um deploy disparado por commit (CI -> tag -> ArgoCD -> rollout)
#   rightsizing -> compara uso real (kubectl top) com requests dos manifests
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
case "${1:-}" in
  selfheal)
    step "Mudança manual proibida: kubectl scale deploy/ngo-service --replicas=5" "simula alguém 'clicando' no cluster"
    kubectl -n solidarytech scale deploy/ngo-service --replicas=5
    step "Observando o ArgoCD reverter (selfHeal)" "o estado desejado é o git, não o cluster"
    for i in $(seq 1 30); do
      R=$(kubectl -n solidarytech get deploy ngo-service -o jsonpath='{.spec.replicas}'); echo "    replicas=$R"
      [ "$R" != "5" ] && { ok "revertido pelo ArgoCD em ~$((i*5))s"; break; }; sleep 5
    done ;;
  rollout)
    step "Acompanhando rollout do donation-service" "tag nova vinda do CI; RollingUpdate maxUnavailable=0"
    kubectl -n solidarytech rollout status deploy/donation-service
    kubectl -n solidarytech get deploy donation-service -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
    kubectl -n argocd get app solidarytech -o jsonpath='{.status.sync.revision}'; echo ;;
  rightsizing)
    step "Uso real vs requests (FinOps rightsizing)" "evidência para docs/FINOPS.md"
    kubectl -n solidarytech top pods --containers 2>/dev/null || fail "metrics-server ainda não pronto"
    echo; kubectl -n solidarytech get deploy -o custom-columns='NAME:.metadata.name,CPU_REQ:.spec.template.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.template.spec.containers[0].resources.requests.memory,CPU_LIM:.spec.template.spec.containers[0].resources.limits.cpu,MEM_LIM:.spec.template.spec.containers[0].resources.limits.memory'
    echo; kubectl -n solidarytech get hpa ;;
  *) echo "uso: $0 {selfheal|rollout|rightsizing}"; exit 1 ;;
esac
