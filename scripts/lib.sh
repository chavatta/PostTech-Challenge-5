#!/usr/bin/env bash
# Funções compartilhadas pelos scripts do projeto.
# Cada passo do roteiro chama `step "título" "por quê"` para que, durante a gravação,
# o terminal mostre O QUE está sendo feito e O MOTIVO antes do comando rodar.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Todo comando `aws` precisa de região; o bloco de credenciais do Learner Lab não traz uma.
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"

step() {  # $1 = o que | $2 = por quê
  printf '\n\033[1;36m==> %s\033[0m\n' "$1"
  [ -n "${2:-}" ] && printf '\033[0;37m    motivo: %s\033[0m\n' "$2"
  [ -n "${PAUSE:-}" ] && read -rp "    [enter para executar]" _ || true
}
ok()   { printf '\033[1;32m    ✔ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m    ✖ %s\033[0m\n' "$1"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "ferramenta '$1' não encontrada. $2"; }

# --- Portabilidade (macOS / Linux / Windows via Git Bash ou WSL, qualquer Docker) ---
# No Git Bash (MSYS) o shell converte caminhos POSIX em argumentos ("/src" vira "C:\Program Files\Git\src").
# MSYS_NO_PATHCONV=1 desliga isso, e hostpath() converte o lado do host para o formato que o Docker Desktop entende.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1; IS_WINDOWS=1 ;; *) IS_WINDOWS= ;; esac
hostpath() {  # caminho absoluto do host pronto para "-v <host>:<container>"
  if [ -n "$IS_WINDOWS" ] && command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
# Docker Compose v2 é obrigatório ("docker compose"). Docker Desktop, Colima, Rancher, OrbStack e Podman Desktop servem.
compose() { docker compose "$@"; }
