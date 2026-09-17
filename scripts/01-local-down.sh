#!/usr/bin/env bash
# Derruba o ambiente local e apaga volumes (deixa a máquina limpa para a próxima gravação).
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"
step "Derrubando ambiente local" "libera recursos e garante que a próxima execução parte do zero"
docker compose -f local/docker-compose.yml down -v --remove-orphans
ok "ambiente local removido"
