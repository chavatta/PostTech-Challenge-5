#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 00 - Pré-voo: confirma que a máquina tem tudo para rodar o projeto.
# Rodar sempre no início de uma sessão (principalmente no ambiente 2, de gravação).
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

step "Verificando ferramentas de linha de comando" \
     "sem elas nenhuma etapa funciona; melhor descobrir agora do que no meio da gravação"
need docker    "instale Docker Desktop (Win/Mac/Linux), Colima, Rancher Desktop ou OrbStack"
need git       "https://git-scm.com (no Windows, use o Git Bash para rodar os scripts)"
need gh        "https://cli.github.com e depois: gh auth login"
need aws       "https://aws.amazon.com/cli (v2)"
need terraform "https://developer.hashicorp.com/terraform/install"
need kubectl   "https://kubernetes.io/docs/tasks/tools"
ok "docker $(docker --version | cut -d' ' -f3)"
ok "terraform $(terraform version | head -1 | cut -d' ' -f2)"
ok "aws-cli $(aws --version | cut -d' ' -f1 | cut -d/ -f2)"

step "Verificando daemon do Docker" "os builds e o ambiente local dependem dele"
docker info >/dev/null 2>&1 || fail "docker daemon não está rodando (abra o Docker Desktop, ou 'colima start', etc.)"
ok "docker daemon ativo (context: $(docker context show), SO: $(uname -s))"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 ausente: precisa do comando 'docker compose' (plugin). Docker Desktop já inclui; no Colima/Linux: instale docker-compose-plugin"
ok "docker compose $(docker compose version --short)"

step "Verificando login no GitHub" "o CI/CD e o GitOps leem deste repositório"
gh auth status >/dev/null 2>&1 && ok "gh autenticado como $(gh api user -q .login)" || fail "rode: gh auth login"

echo; ok "Pré-voo concluído."
