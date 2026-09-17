#!/bin/bash
# Executado automaticamente pela imagem oficial do Postgres na primeira inicialização
# (/docker-entrypoint-initdb.d). Cria os dois bancos e aplica os schemas originais do repositório.
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" <<-EOSQL
  CREATE DATABASE ngo_db;
  CREATE DATABASE donation_db;
EOSQL
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d ngo_db      -f /sql/ngo-init.sql
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d donation_db -f /sql/donation-init.sql
echo ">>> bancos ngo_db e donation_db criados"
