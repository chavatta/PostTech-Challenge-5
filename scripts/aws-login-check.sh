#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Confirma que as credenciais do AWS Academy estão válidas.
# Como obter: Learner Lab -> Start Lab -> "AWS Details" -> "AWS CLI: Show" -> colar em ~/.aws/credentials
# As credenciais expiram a cada sessão (~4h). Rode este script no início de cada etapa.
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

step "Validando credenciais AWS" "no Learner Lab elas expiram; um apply pela metade com token vencido deixa lixo na conta"
ID=$(aws sts get-caller-identity 2>&1) || fail "credenciais inválidas/expiradas. Copie o bloco 'AWS CLI' do Learner Lab para ~/.aws/credentials"
ok "conta $(echo "$ID" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["Account"], "-", d["Arn"].split("/")[-1])')"

step "Confirmando que a LabRole existe" "o Terraform usa essa role para o EKS; não podemos criar IAM roles no Academy"
aws iam get-role --role-name LabRole --query 'Role.Arn' --output text && ok "LabRole encontrada"
