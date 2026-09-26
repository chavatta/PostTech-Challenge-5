#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 05 - Etapa 5: Observabilidade. Prometheus/Grafana/Loki já sobem pelo ArgoCD (Etapa 4).
# Este script:
#   1) confere o Secret da licença New Relic (criado na Etapa 4 a partir de NEW_RELIC_LICENSE_KEY)
#   2) reinicia os deployments para o agente APM começar a reportar
#   3) abre os acessos (port-forward) e gera tráfego para popular dashboards e traces
# Uso: NEW_RELIC_LICENSE_KEY=xxxx scripts/05-observability.sh
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"

step "Apontando para o site primário (workspace terraform + contexto kubectl)" \
     "se '02-terraform-apply.sh dr' rodou antes, o kubectl ficou no cluster do DR; esta etapa é do primário"
use_site primary
ok "kubectl -> $(kubectl config current-context) ($REGION)"

step "Secret newrelic-license (já criado na Etapa 4; reaplica se a licença mudou)" \
     "a licença é lida da variável de ambiente e vai direto para o cluster; nunca para o git"
ensure_newrelic_secret
ok "secret confere"

step "Reiniciando os 3 serviços para carregar o agente APM" "envFrom secretRef optional: sem restart o pod antigo não vê o secret"
kubectl -n solidarytech rollout restart deploy ngo-service donation-service volunteer-service
kubectl -n solidarytech rollout status deploy/donation-service --timeout=180s
ok "agentes ativos (NEW_RELIC_APP_NAME=solidarytech-<serviço>)"

step "Forçando sync do nri-bundle (integração Kubernetes do New Relic)" "o chart lê o secret via customSecretName"
kubectl -n argocd annotate app newrelic argocd.argoproj.io/refresh=hard --overwrite >/dev/null
ok "ArgoCD vai reconciliar o app newrelic"

step "Gerando tráfego (2 min) para popular Golden Metrics, SLOs e traces" "dashboards vazios não provam nada"
LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
END=$((SECONDS+120)); N=0
while [ $SECONDS -lt $END ]; do
  curl -s -o /dev/null "http://$LB/donations"; curl -s -o /dev/null "http://$LB/ngos"; curl -s -o /dev/null "http://$LB/volunteers/1"
  curl -s -o /dev/null -X POST "http://$LB/donations" -H 'Content-Type: application/json' -d '{"ngo_id":1,"amount":10,"donor_name":"load"}'
  N=$((N+4)); printf "\r    %d requisições" $N; sleep 0.2
done; echo; ok "tráfego gerado"

step "Acessos" "para o vídeo"
cat <<EOT
    Grafana:     kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80   -> http://localhost:3000 (admin / solidarytech-grafana)
                 Dashboard: "SRE — donation-service SLOs & Error Budget"
    Prometheus:  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
                 Alerts -> regras donation-service.slo-alerts
    Loki:        no Grafana -> Explore -> datasource Loki -> {namespace="solidarytech"}
    New Relic:   APM & Services -> solidarytech-donation-service -> Distributed tracing
EOT
