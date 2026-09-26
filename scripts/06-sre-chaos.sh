#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 06 - Etapa 6: demonstrações de SRE (para evidenciar SLO, error budget e MTTR no vídeo).
#   errors   -> injeta erros 5xx (renomeia a tabela donations no RDS: simula migração/DDL quebrada), gera tráfego
#               até o alerta de burn rate disparar e mitiga pelo runbook (mede MTTD e MTTR)
#   kill     -> mata pods do donation-service; liveness/HPA/PDB mantêm o serviço (auto healing)
#   load     -> pico de carga; HPA escala (Golden Metric de saturação)
#   restore  -> desfaz à mão a falha do "errors" (só se uma execução interrompida não conseguiu desfazer)
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Falha de banco determinística: com a tabela renomeada, INSERT/SELECT dão "relation does not exist" e o app
# responde 500 na hora (o /health não toca no banco, então os pods seguem Ready e não reiniciam).
# NetworkPolicy não serve: políticas só somam permissões e a backend-default já libera o 5432 para o donation-service.
INJECT_SQL='ALTER TABLE donations RENAME TO donations_chaos'
# Idempotente: só age se a falha estiver injetada. Se um sync do ArgoCD rodou o db-init durante o caos, ele recriou
# "donations" vazia e o app voltou a gravar nela; essas linhas são copiadas antes de trocar a tabela de volta.
RESTORE_SQL=$(cat <<'SQL'
DO $chaos$ BEGIN
  IF to_regclass('donations_chaos') IS NULL THEN RETURN; END IF;
  IF to_regclass('donations') IS NOT NULL THEN
    INSERT INTO donations_chaos (ngo_id, amount, donor_name, status, created_at)
      SELECT ngo_id, amount, donor_name, status, created_at FROM donations;
    DROP TABLE donations;
  END IF;
  ALTER TABLE donations_chaos RENAME TO donations;
END $chaos$
SQL
)
# Roda o SQL no donation_db num pod efêmero, com o mesmo usuário da aplicação (dono da tabela, criada pelo db-init).
# O securityContext atende o Pod Security "restricted" do namespace (igual ao Job db-init). A URL do banco vai do
# Secret direto para o pod: '$(DB)' é expandido pelo kubelet, então a senha não aparece no terminal gravado.
# Nome do pod fica em CHAOS_POD (global, sem local): se o Ctrl+C derrubar o kubectl antes do --rm, o cleanup apaga o pod.
chaos_sql() {  # $1 = SQL
  CHAOS_POD="chaos-sql-$RANDOM"   # nome único: o pod anterior pode ainda estar sendo apagado
  kubectl -n solidarytech run "$CHAOS_POD" --rm -i --quiet --restart=Never --image=postgres:16-alpine \
    --override-type=strategic \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":70,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"'"$CHAOS_POD"'","env":[{"name":"DB","valueFrom":{"secretKeyRef":{"name":"db-credentials","key":"donation_db_url"}}}],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
    --command -- psql -X -v ON_ERROR_STOP=1 -c "$1" '$(DB)'
}
post() {  # imprime só o status HTTP do POST /donations (000 = sem resposta); nunca aborta o script
  curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "http://$LB/donations" \
    -H 'Content-Type: application/json' -d "{\"ngo_id\":1,\"amount\":1,\"donor_name\":\"$1\"}" || true
}
PROM=http://localhost:19090   # porta local própria: não briga com um port-forward 9090 aberto na Etapa 5
alert_state() {  # firing | pending | inactive do DonationAvailabilityBurnRateCritical
  local r
  r=$(curl -s -m 3 "$PROM/api/v1/query" --data-urlencode 'query=ALERTS{alertname="DonationAvailabilityBurnRateCritical"}' || true)
  case "$r" in *'"alertstate":"firing"'*) echo firing ;; *'"alertstate":"pending"'*) echo pending ;; *) echo inactive ;; esac
}
PF= INJECTED=
cleanup() {  # qualquer saída (erro, Ctrl+C, fim normal) desfaz a falha e fecha o port-forward
  if [ -n "$INJECTED" ]; then
    printf "\n    desfazendo a falha injetada antes de sair...\n"
    # Ctrl+C no meio do chaos_sql mata o kubectl sem o --rm: o pod da injeção seguiria vivo e poderia renomear a tabela
    # DEPOIS do restore. O delete espera o pod sumir, então a injeção ou já rodou (e o restore desfaz) ou não roda mais.
    [ -n "${CHAOS_POD:-}" ] && kubectl -n solidarytech delete pod "$CHAOS_POD" --ignore-not-found >/dev/null 2>&1 || true
    chaos_sql "$RESTORE_SQL" || printf '\033[1;31m    ✖ não consegui desfazer: rode scripts/06-sre-chaos.sh restore\033[0m\n'
  fi
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
}

case "${1:-}" in
  errors)
    [ -n "$LB" ] || fail "LoadBalancer do ingress-nginx ainda sem hostname (a Etapa 4 terminou?)"
    trap cleanup EXIT; trap 'exit 130' INT TERM
    step "Abrindo port-forward do Prometheus (localhost:19090)" \
         "o script consulta o próprio alerta para medir a detecção (MTTD), em vez de esperar uma janela fixa"
    kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 >/dev/null 2>&1 & PF=$!
    for _ in $(seq 1 20); do curl -fs -m 2 "$PROM/-/ready" >/dev/null && break; sleep 1; done
    curl -fs -m 2 "$PROM/-/ready" >/dev/null || fail "Prometheus não respondeu no port-forward"
    # sem a regra carregada o alerta nunca dispara: melhor falhar agora do que depois de 10 min de erro em produção
    # (resposta em variável: "curl | grep -q" com pipefail falha à toa quando o grep fecha o pipe cedo)
    RULES=$(curl -s -m 5 "$PROM/api/v1/rules" || true)
    case "$RULES" in *DonationAvailabilityBurnRateCritical*) ;;
      *) fail "regra DonationAvailabilityBurnRateCritical não carregada no Prometheus (app platform-config sincronizada?)" ;; esac
    [ "$(alert_state)" != firing ] || fail "alerta já está FIRING (erros de uma execução anterior ainda na janela de 5m); espere resolver em Prometheus → Alerts e rode de novo"
    ok "Prometheus pronto; alerta DonationAvailabilityBurnRateCritical inativo"

    step "Injetando falha: tabela donations renomeada no RDS (simula migração/DDL quebrada)" \
         "POST e GET /donations passam a retornar 500 na hora. Daqui até a recuperação o relógio do MTTR corre e nenhum passo pausa"
    INJECTED=1   # antes do SQL: se a injeção cair no meio, o trap ainda desfaz
    chaos_sql "$INJECT_SQL" || fail "não consegui injetar a falha (ver erro acima)"
    START=$(date +%s)

    # PAUSE= : mostra o passo sem esperar enter, para a pausa da gravação não entrar no MTTD/MTTR
    PAUSE= step "Gerando tráfego com erro até o alerta disparar" \
         "SLI 5m cai, burn rate passa de 14,4x nas janelas 1h e 5m; o alerta fica pending e vira firing após o for: 2m"
    while :; do
      for _ in $(seq 1 10); do CODE=$(post chaos); sleep 0.2; done   # ~4 req/s de 500
      NOW=$(date +%s); STATE=$(alert_state)
      printf '\r    +%4ss  último POST: HTTP %s  alerta: %-8s' "$((NOW - START))" "$CODE" "$STATE"
      [ "$STATE" = firing ] && break
      [ $((NOW - START)) -lt 600 ] || { echo; fail "alerta não disparou em 10 min (regras carregadas? ver Prometheus → Alerts)"; }
      kill -0 "$PF" 2>/dev/null || { echo; fail "port-forward do Prometheus caiu"; }
    done; echo
    DETECT=$(date +%s)
    ok "alerta FIRING: detecção (MTTD) em $((DETECT - START))s"

    PAUSE= step "Mitigação pelo runbook (docs/ITSM.md#runbook-donation-5xx): desfazer a mudança no banco" \
         "detecção foi automática (alerta) e o diagnóstico vem do trace/Loki (relation \"donations\" does not exist); a tabela não está no git, então o ArgoCD não desfaz sozinho e a correção segue o runbook"
    chaos_sql "$RESTORE_SQL"; INJECTED=
    REC=
    for _ in $(seq 1 60); do
      [ "$(post ok)" = 201 ] && { REC=$(date +%s); break; }
      sleep 2
    done
    [ -n "$REC" ] || fail "serviço não recuperou em 2 min após a mitigação"
    ok "serviço recuperado (POST /donations = 201)"
    ok "MTTR $((REC - START))s = detecção $((DETECT - START))s + correção $((REC - DETECT))s (anotar no relatório)"
    echo "    o alerta resolve sozinho quando a janela de 5m deixar de conter os erros (~5 min): ver Prometheus → Alerts" ;;
  kill)
    step "Matando todos os pods do donation-service" "auto healing: Deployment recria, readiness segura o tráfego, PDB protege drains"
    kubectl -n solidarytech delete pod -l app=donation-service --wait=false
    for i in $(seq 1 20); do curl -fsS -o /dev/null "http://$LB/health" && echo "    $(date +%T) health OK" || echo "    $(date +%T) health FALHOU"; sleep 2; done
    kubectl -n solidarytech get pods -l app=donation-service ;;
  load)
    step "Pico de carga (60s, 16 conexões) direto no Service do donation-service" \
         "HPA escala pelo CPU 70%; saturação no dashboard. O gerador roda no namespace ingress-nginx (sem PSS restricted e aceito pela NetworkPolicy backend-default) e não passa pelo Ingress, cujo limit-rps 50 por IP devolveria 503 e seguraria a carga"
    kubectl -n ingress-nginx delete pod loadgen --ignore-not-found >/dev/null   # sobra de uma execução interrompida
    # securityContext compatível com "restricted" (a imagem roda como root por padrão): vale em qualquer namespace
    kubectl -n ingress-nginx run loadgen --rm -i --quiet --restart=Never --image=williamyeh/hey \
      --override-type=strategic \
      --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"loadgen","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
      -- -z 60s -c 16 "http://donation-service.solidarytech/donations" || fail "gerador de carga não rodou (ver erro acima)"
    kubectl -n solidarytech get hpa donation-service; kubectl -n solidarytech get pods -l app=donation-service ;;
  restore)
    step "Desfazendo a falha do modo errors" "só é preciso se uma execução interrompida não conseguiu desfazer; sem falha injetada, não faz nada"
    chaos_sql "$RESTORE_SQL"
    ok "tabela donations no lugar" ;;
  *) echo "uso: $0 {errors|kill|load|restore}"; exit 1 ;;
esac
