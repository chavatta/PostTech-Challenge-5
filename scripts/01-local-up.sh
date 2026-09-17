#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 01 - Etapa 1: builda as 3 imagens e sobe o ambiente local (Postgres + LocalStack).
# Depois executa um smoke test ponta a ponta nos 3 serviços.
# Objetivo para o vídeo: provar que os Dockerfiles funcionam ANTES de ir para a nuvem.
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"

step "Build das imagens + subida do ambiente local" \
     "multi-stage builds geram imagens pequenas; LocalStack emula SQS/DynamoDB sem custo AWS"
docker compose -f local/docker-compose.yml up -d --build --wait
ok "containers no ar"

step "Tamanho das imagens geradas" \
     "evidência de otimização: distroless (Go) e python-slim non-root"
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | grep solidarytech

step "Smoke test: health dos 3 serviços" "readiness básico; é o mesmo endpoint usado pelas probes do Kubernetes"
for p in 8081 8082 8083; do
  curl -fsS "http://localhost:$p/health" && echo
done

step "Smoke test: fluxo de negócio (ONG -> doação -> voluntário)" \
     "valida integração com Postgres, SQS e DynamoDB"
NGO_ID=$(curl -fsS -X POST localhost:8081/ngos -H 'Content-Type: application/json' \
  -d '{"name":"Mãos que Ajudam","email":"contato@maosqueajudam.org","cause":"Fome","city":"Campinas"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
ok "ONG criada id=$NGO_ID"

curl -fsS -X POST localhost:8082/donations -H 'Content-Type: application/json' \
  -d "{\"ngo_id\":$NGO_ID,\"amount\":150.00,\"donor_name\":\"Doador Anônimo\"}" && echo
ok "doação registrada (hot path)"

curl -fsS -X POST localhost:8083/volunteers -H 'Content-Type: application/json' \
  -d "{\"name\":\"Ana Voluntária\",\"email\":\"ana@example.org\",\"ngo_id\":$NGO_ID}" && echo
ok "voluntário registrado no DynamoDB (LocalStack)"

step "Verificando que a doação virou evento na fila SQS" \
     "prova a integração assíncrona do donation-service"
docker compose -f local/docker-compose.yml exec -T localstack \
  awslocal sqs receive-message --queue-url http://localhost:4566/000000000000/solidary-donations \
  --max-number-of-messages 1 | python3 -c 'import sys,json;m=json.load(sys.stdin)["Messages"][0];print(m["Body"])'
ok "evento SQS recebido"

echo; ok "Etapa 1 validada. Para derrubar: scripts/01-local-down.sh"
