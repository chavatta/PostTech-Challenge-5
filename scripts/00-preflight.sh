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
need gh        "https://cli.github.com (Windows: winget install GitHub.cli; Ubuntu/WSL: repositório oficial, o apt padrão é antigo) e depois: gh auth login"
need aws       "AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html (Windows: winget install Amazon.AWSCLI)"
need terraform "https://developer.hashicorp.com/terraform/install (Windows: winget install Hashicorp.Terraform)"
need kubectl   "https://kubernetes.io/docs/tasks/tools (Windows: winget install Kubernetes.kubectl)"
need curl      "Ubuntu/WSL: sudo apt install -y curl (Git Bash e macOS já trazem)"
ok "docker $(docker --version | cut -d' ' -f3)"
ok "terraform $(terraform version | head -1 | cut -d' ' -f2)"
# python3 é função do lib.sh (acha o interpretador de verdade; no Windows o 'python3' da Store não executa nada)
python3 -c 'import json' >/dev/null || fail "Python 3.8+ é obrigatório (lê o JSON das CLIs): veja a mensagem acima"
ok "python $(python3 -c 'import platform; print(platform.python_version())') (${PY[*]})"
# AWS CLI >= 2.6.3: a v1 do apt do Ubuntu e v2 antigas gravam kubeconfig v1alpha1, que o kubectl atual recusa
AWSV=$(aws --version 2>&1 | tr -d '\r' | cut -d' ' -f1 | cut -d/ -f2)
IFS=. read -r AWS_MA AWS_MI AWS_PA _ <<<"$AWSV.0.0"
if [ "${AWS_MA:-0}" -gt 2 ] 2>/dev/null || { [ "${AWS_MA:-0}" -eq 2 ] && { [ "${AWS_MI:-0}" -gt 6 ] || { [ "${AWS_MI:-0}" -eq 6 ] && [ "${AWS_PA:-0}" -ge 3 ]; }; }; } 2>/dev/null; then
  ok "aws-cli $AWSV"
else
  fail "aws-cli '$AWSV': precisa da v2 >= 2.6.3 (a v1 do apt do Ubuntu gera kubeconfig que o kubectl recusa). Ubuntu: sudo apt remove awscli e instale a v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
fi

step "Verificando fim de linha do checkout" "no Windows, checkout com CRLF quebra os scripts bash e os scripts de init dos containers"
if git -C "$ROOT_HOST" ls-files --eol 2>/dev/null | grep -q 'w/crlf'; then
  fail "há arquivos com CRLF no checkout. Rode: git -C \"$ROOT_DIR\" rm -r --cached -q . && git -C \"$ROOT_DIR\" reset --hard (o .gitattributes do repo força LF)"
fi
ok "checkout com LF"

step "Verificando daemon do Docker" "os builds e o ambiente local dependem dele"
docker info >/dev/null 2>&1 || fail "docker daemon não está rodando (abra o Docker Desktop, ou 'colima start', etc.)"
ok "docker daemon ativo (context: $(docker context show), SO: $(uname -s))"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 ausente: precisa do comando 'docker compose' (plugin). Docker Desktop já inclui; no Colima/Linux: instale docker-compose-plugin"
ok "docker compose $(docker compose version --short)"

step "Verificando login no GitHub" "o CI/CD e o GitOps leem deste repositório"
gh auth status >/dev/null 2>&1 && ok "gh autenticado como $(gh api user -q .login)" || fail "rode: gh auth login"
# a Etapa 4 usa 'gh auth token' (gh >= 2.17); o gh do apt do Ubuntu 22.04 (2.4.0) não tem e imprime o uso no stdout
gh auth token >/dev/null 2>&1 || fail "gh $(gh --version | head -1 | awk '{print $3}') sem 'gh auth token' (precisa >= 2.17): https://github.com/cli/cli/blob/trunk/docs/install_linux.md"

echo; ok "Pré-voo concluído."
