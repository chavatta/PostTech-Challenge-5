#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 03 - Etapa 3: reproduz localmente os mesmos gates do pipeline (shift-left) e
# acompanha a execução real no GitHub Actions.
# Uso: scripts/03-ci-check.sh          -> roda testes/scans locais em containers
#      scripts/03-ci-check.sh watch    -> acompanha o último run do CI no GitHub
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"

if [ "${1:-}" = "watch" ]; then
  step "Acompanhando o pipeline no GitHub Actions" "mesmos gates que rodamos localmente, agora bloqueando o merge"
  gh run watch --exit-status "$(gh run list --workflow ci --limit 1 --json databaseId -q '.[0].databaseId')"
  gh run list --workflow ci --limit 3
  exit 0
fi

step "Testes unitários Go (donation-service)" "hot path precisa de testes; o original não tinha nenhum"
docker run --rm -v "$(hostpath "$PWD/services/donation-service")":/src -w /src golang:1.26-alpine go test -cover ./...

step "Lint (ruff, incl. regras bandit) + testes Python (volunteer-service)" "SAST leve direto no lint"
docker run --rm -v "$(hostpath "$PWD/services/volunteer-service")":/src -w /src \
  -e AWS_DYNAMODB_TABLE=x -e AWS_ACCESS_KEY_ID=t -e AWS_SECRET_ACCESS_KEY=t \
  python:3.12-slim sh -c "pip install -q -r requirements-dev.txt && ruff check . && pytest -q"

step "Lint + testes Python (ngo-service) com Postgres efêmero" "testes de integração reais contra o schema"
docker network create ci-local >/dev/null 2>&1 || true
docker run -d --rm --name ci-pg --network ci-local \
  -e POSTGRES_USER=solidary -e POSTGRES_PASSWORD=solidary -e POSTGRES_DB=ngo_db \
  -v "$(hostpath "$PWD/services/ngo-service/db/init.sql")":/docker-entrypoint-initdb.d/init.sql:ro postgres:16-alpine >/dev/null
for i in $(seq 1 20); do docker exec ci-pg pg_isready -U solidary -d ngo_db >/dev/null 2>&1 && break; sleep 1; done
docker run --rm --network ci-local -v "$(hostpath "$PWD/services/ngo-service")":/src -w /src \
  -e DATABASE_URL=postgres://solidary:solidary@ci-pg:5432/ngo_db \
  python:3.12-slim sh -c "pip install -q -r requirements-dev.txt && ruff check . && pytest -q" \
  ; RC=$?
docker rm -f ci-pg >/dev/null; docker network rm ci-local >/dev/null
[ $RC -eq 0 ] || fail "testes do ngo-service falharam"

step "Trivy: SCA das dependências + IaC do Terraform" "mesmo scanner do pipeline; falha em CRITICAL/HIGH"
docker run --rm -v "$(hostpath "$PWD")":/repo -w /repo aquasec/trivy:0.56.2 fs --scanners vuln,secret,misconfig --skip-check-update \
  --severity CRITICAL,HIGH --ignore-unfixed --ignorefile .trivyignore --exit-code 1 .

step "Trivy: scan das imagens locais" "gate de imagem: nada com CRITICAL sobe para o cluster"
compose -f local/docker-compose.yml build -q
# As imagens são exportadas com "docker save" e escaneadas a partir do tar: funciona em qualquer SO e qualquer
# runtime (Docker Desktop, Colima, Rancher, Podman), sem depender do socket /var/run/docker.sock, que não existe no Windows.
TMP="$ROOT_DIR/.tmp-ci"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT
for s in ngo-service donation-service volunteer-service; do
  docker save "solidarytech/$s:local" -o "$(hostpath "$TMP")/$s.tar"   # docker.exe não entende /c/... (conversão desligada)
  docker run --rm -v "$(hostpath "$TMP")":/scan aquasec/trivy:0.56.2 image \
    --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 --input "/scan/$s.tar" || fail "$s tem CVEs bloqueantes"; ok "$s limpo"
  rm -f "$TMP/$s.tar"
done

echo; ok "Todos os gates passaram localmente. git push dispara os mesmos no GitHub Actions."
