#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Demonstrações de GitOps para o vídeo:
#   selfheal  -> altera o HPA na mão e mostra o ArgoCD revertendo (ninguém mexe no cluster sem git)
#   rollout   -> acompanha um deploy disparado por commit (CI -> tag -> ArgoCD -> rollout)
#   rightsizing -> compara uso real (kubectl top) com requests dos manifests
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
case "${1:-}" in
  selfheal)
    # Não dá para demonstrar com "kubectl scale": o Application ignora /spec/replicas (o HPA manda nas réplicas),
    # então quem desfaria o scale seria o HPA, não o ArgoCD. O maxReplicas do HPA é comparado com o git e nenhum
    # controlador mexe nele: se voltar ao valor do git, foi o selfHeal.
    WANT=$(awk '$1 == "maxReplicas:" {print $2; exit}' "$ROOT_DIR/gitops/base/ngo-service/hpa.yaml")
    [ -n "$WANT" ] || fail "maxReplicas não encontrado em gitops/base/ngo-service/hpa.yaml"
    DRIFT=$((WANT + 7))
    step "Mudança manual proibida: maxReplicas do HPA ngo-service $WANT -> $DRIFT (kubectl patch)" "simula alguém 'clicando' no cluster"
    kubectl -n solidarytech patch hpa ngo-service --type merge -p "{\"spec\":{\"maxReplicas\":$DRIFT}}"
    T0=$SECONDS; R=""   # relógio a partir do patch: o selfHeal leva poucos segundos
    # PAUSE= : sem esperar enter, senão o ArgoCD reverte durante a pausa e o vídeo não mostra o drift/OutOfSync
    PAUSE= step "Observando o ArgoCD reverter (selfHeal)" "o estado desejado é o git (maxReplicas=$WANT), não o cluster; o app passa por OutOfSync"
    for _ in $(seq 1 90); do   # a cada 2s (3 min no total): o revert leva segundos e 5s pularia o OutOfSync
      R=$(kubectl -n solidarytech get hpa ngo-service -o jsonpath='{.spec.maxReplicas}')
      echo "    maxReplicas=$R  argocd=$(kubectl -n argocd get app solidarytech -o jsonpath='{.status.sync.status}')"
      [ "$R" = "$WANT" ] && { ok "revertido pelo ArgoCD em ~$((SECONDS - T0))s"; break; }; sleep 2
    done
    [ "$R" = "$WANT" ] || fail "maxReplicas ainda é $R após 3 min: confira o selfHeal do Application solidarytech"
    # Prova de que foi o ArgoCD: o último sync foi automático (selfHeal), não disparado por pessoa.
    kubectl -n argocd get app solidarytech -o jsonpath='    último sync: automated={.status.operationState.operation.initiatedBy.automated} início={.status.operationState.startedAt} fase={.status.operationState.phase}{"\n"}' ;;
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
