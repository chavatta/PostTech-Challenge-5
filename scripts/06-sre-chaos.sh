#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 06 - Etapa 6: demonstrações de SRE (para evidenciar SLO, error budget e MTTR no vídeo).
#   errors   -> injeta erros 5xx (derruba a conectividade do donation-service com o banco) e mostra
#               o SLI caindo, o alerta de burn rate disparando e a mitigação pelo runbook (mede o MTTR)
#   kill     -> mata pods do donation-service; liveness/HPA/PDB mantêm o serviço (auto healing)
#   load     -> pico de carga; HPA escala (Golden Metric de saturação)
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
case "${1:-}" in
  errors)
    step "Injetando falha: NetworkPolicy bloqueia o donation-service de falar com o RDS" \
         "simula incidente real (banco inacessível); POST /donations passa a retornar 500"
    kubectl -n solidarytech apply -f - <<'EOT'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: chaos-block-db }
spec:
  podSelector: { matchLabels: { app: donation-service } }
  policyTypes: [Egress]
  egress:
    - to: [{ namespaceSelector: {}, podSelector: { matchLabels: { k8s-app: kube-dns } } }]
EOT
    START=$(date +%s)
    step "Gerando tráfego com erro por 3 min" "SLI 5m cai, burn rate sobe, alerta DonationAvailabilityBurnRateCritical dispara"
    END=$((SECONDS+180)); while [ $SECONDS -lt $END ]; do curl -s -o /dev/null -X POST "http://$LB/donations" -H 'Content-Type: application/json' -d '{"ngo_id":1,"amount":1,"donor_name":"chaos"}'; sleep 0.1; done
    step "Mitigação pelo runbook (docs/ITSM.md#runbook-donation-5xx): remover a causa" \
         "detecção e diagnóstico foram automáticos (alerta + trace); a correção segue o runbook. O ArgoCD só gerencia o que está no git, então o recurso injetado é removido aqui"
    kubectl -n solidarytech delete netpol chaos-block-db --ignore-not-found >/dev/null
    for i in $(seq 1 30); do curl -fsS -o /dev/null -X POST "http://$LB/donations" -H 'Content-Type: application/json' -d '{"ngo_id":1,"amount":1,"donor_name":"ok"}' && break; sleep 2; done
    ok "serviço recuperado. MTTR ≈ $(( $(date +%s) - START - 180 ))s após o fim da injeção (anotar no relatório)" ;;
  kill)
    step "Matando todos os pods do donation-service" "auto healing: Deployment recria, readiness segura o tráfego, PDB protege drains"
    kubectl -n solidarytech delete pod -l app=donation-service --wait=false
    for i in $(seq 1 20); do curl -fsS -o /dev/null "http://$LB/health" && echo "    $(date +%T) health OK" || echo "    $(date +%T) health FALHOU"; sleep 2; done
    kubectl -n solidarytech get pods -l app=donation-service ;;
  load)
    step "Pico de carga (60s, 16 conexões)" "HPA escala pelo CPU 70%; saturação no dashboard"
    kubectl run -n solidarytech loadgen --rm -i --restart=Never --image=williamyeh/hey -- -z 60s -c 16 "http://ingress-nginx-controller.ingress-nginx/donations" 2>/dev/null || true
    kubectl -n solidarytech get hpa; kubectl -n solidarytech get pods -l app=donation-service ;;
  *) echo "uso: $0 {errors|kill|load}"; exit 1 ;;
esac
