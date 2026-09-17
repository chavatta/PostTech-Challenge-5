#!/usr/bin/env bash
# Funções compartilhadas pelos scripts do projeto.
# Cada passo do roteiro chama `step "título" "por quê"` para que, durante a gravação,
# o terminal mostre O QUE está sendo feito e O MOTIVO antes do comando rodar.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step() {  # $1 = o que | $2 = por quê
  printf '\n\033[1;36m==> %s\033[0m\n' "$1"
  [ -n "${2:-}" ] && printf '\033[0;37m    motivo: %s\033[0m\n' "$2"
  [ -n "${PAUSE:-}" ] && read -rp "    [enter para executar]" _ || true
}
ok()   { printf '\033[1;32m    ✔ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m    ✖ %s\033[0m\n' "$1"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "ferramenta '$1' não encontrada. $2"; }
