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

# --- Bucket do Velero x SCP do AWS Academy ---
# Algumas contas do Academy têm SCP que nega s3:GetBucketObjectLockConfiguration; o provider AWS chama essa API
# ao ler qualquer aws_s3_bucket e falha. velero_bucket_tf_allowed testa a permissão num bucket real
# (o próprio, se já existir; senão um bucket temporário) e responde se o Terraform pode gerenciá-lo.
velero_bucket_tf_allowed() {  # $1 = nome do bucket do Velero; retorno 0 = pode, 1 = SCP nega
  local b="$1" probe="" err rc=0
  if ! aws s3api head-bucket --bucket "$b" 2>/dev/null; then
    probe="solidarytech-probe-$(date +%s)-$RANDOM"
    s3_create_bucket "$probe"; b="$probe"
  fi
  err=$(aws s3api get-object-lock-configuration --bucket "$b" 2>&1 >/dev/null) || case "$err" in *AccessDenied*) rc=1 ;; esac
  [ -n "$probe" ] && aws s3api delete-bucket --bucket "$probe"
  return $rc
}
velero_bucket_name() {  # $1 = site; mesma regra do módulo registry: <project>-<site>-velero-<account_id>
  printf '%s-%s-velero-%s' "${TF_VAR_project:-solidarytech}" "$1" "$(aws sts get-caller-identity --query Account --output text)"
}
s3_create_bucket() {  # us-east-1 não aceita LocationConstraint
  if [ "$AWS_DEFAULT_REGION" = "us-east-1" ]; then aws s3api create-bucket --bucket "$1" >/dev/null
  else aws s3api create-bucket --bucket "$1" --create-bucket-configuration LocationConstraint="$AWS_DEFAULT_REGION" >/dev/null; fi
}
# Cria (se preciso) o bucket com as MESMAS propriedades do módulo terraform/modules/registry. Idempotente.
ensure_velero_bucket() {  # $1 = nome do bucket
  aws s3api head-bucket --bucket "$1" 2>/dev/null || s3_create_bucket "$1"
  aws s3api put-bucket-tagging --bucket "$1" --tagging 'TagSet=[{Key=Project,Value=SolidaryTech},{Key=Environment,Value=Production},{Key=CostCenter,Value=NGO-Core},{Key=ManagedBy,Value=Script}]'
  aws s3api put-bucket-versioning --bucket "$1" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$1" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$1" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-lifecycle-configuration --bucket "$1" --lifecycle-configuration '{"Rules":[{"ID":"expire-old-backups","Status":"Enabled","Filter":{},"Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":7}}]}'
}
