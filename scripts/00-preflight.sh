#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 00 - Pré-voo: confirma que a máquina tem tudo para rodar o projeto.
# Rodar sempre no início de uma sessão (principalmente no ambiente 2, de gravação).
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

step "Verificando ferramentas de linha de comando" \
     "sem elas nenhuma etapa funciona; melhor descobrir agora do que no meio da gravação"
need docker    "instale Docker Desktop ou Colima (brew install colima docker)"
need git       "brew install git"
need gh        "brew install gh && gh auth login"
need aws       "brew install awscli"
need terraform "brew install terraform"
need kubectl   "brew install kubectl"
ok "docker $(docker --version | cut -d' ' -f3)"
ok "terraform $(terraform version -json | python3 -c 'import sys,json;print(json.load(sys.stdin)["terraform_version"])')"
ok "aws-cli $(aws --version | cut -d' ' -f1 | cut -d/ -f2)"

step "Verificando daemon do Docker" "os builds e o ambiente local dependem dele"
docker info >/dev/null 2>&1 || fail "docker daemon não está rodando (colima start / abra o Docker Desktop)"
ok "docker daemon ativo (context: $(docker context show))"

step "Verificando login no GitHub" "o CI/CD e o GitOps leem deste repositório"
gh auth status >/dev/null 2>&1 && ok "gh autenticado como $(gh api user -q .login)" || fail "rode: gh auth login"

echo; ok "Pré-voo concluído."
