#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Teste de portabilidade dos scripts (roda no CI em Ubuntu, macOS e Windows/Git Bash; também roda local).
# Não usa nuvem: exercita as funções reais do lib.sh que dependem do SO:
#   fim de linha do checkout, python3 (alias da Store no Windows, CRLF, UTF-8), caminhos de host para .exe nativos
#   (terraform -chdir, git -C), leitura dos YAML/tfvars e o pull anônimo do GHCR.
# ------------------------------------------------------------------------------
source "$(dirname "$0")/../lib.sh"
cd "$ROOT_DIR"
FALHAS=0
check() {  # $1 = descrição | $2... = comando que precisa dar exit 0
  local d="$1"; shift
  if "$@"; then ok "$d"; else printf '\033[1;31m    ✖ %s\033[0m\n' "$d"; FALHAS=$((FALHAS + 1)); fi
}
sem_cr() { case "$1" in *$'\r'*) return 1 ;; *) return 0 ;; esac; }

step "Ambiente" "o que este runner é"
ok "SO: $(uname -s) | bash $BASH_VERSION | IS_WINDOWS=[${IS_WINDOWS}] | python: ${PY[*]:-nenhum}"
ok "ROOT_DIR=$ROOT_DIR | ROOT_HOST=$ROOT_HOST"

step "Checkout" "CRLF quebra bash, scripts de init dos containers e leitura de YAML"
check "nenhum arquivo com CRLF no working tree" bash -c "! git ls-files --eol | grep -q 'w/crlf'"
for f in scripts/*.sh scripts/tests/*.sh; do bash -n "$f" || { printf '    ✖ sintaxe: %s\n' "$f"; FALHAS=$((FALHAS + 1)); }; done
ok "sintaxe de todos os scripts"

step "Python" "lê o JSON das CLIs em quase toda etapa"
check "interpretador real encontrado (não o alias da Store)" test ${#PY[@]} -gt 0
X=$(python3 -c 'print("abc")')
check "captura sem \\r: [$X]" test "$X" = abc
X=$(echo '{"a": 7}' | python3 -c 'import sys, json; print(json.load(sys.stdin)["a"])')
check "stdin (pipe) + json" test "$X" = 7
X=$(python3 - <<'PY'
print("heredoc ✔")
PY
)
check "heredoc + UTF-8 num pipe" test "$X" = "heredoc ✔"
RC=0; python3 -c 'import sys; sys.exit(3)' || RC=$?
check "exit code preservado (3)" test "$RC" = 3
read -r A B < <(python3 -c 'print(9, 9)')
check "read de duas colunas sem \\r" test "$B" = 9

step "AWS CLI" "no Windows é Python congelado e escreve CRLF"
if type -P aws >/dev/null 2>&1; then
  X=$(aws --version 2>&1)
  check "aws --version capturado sem \\r" sem_cr "$X"
  X=$(aws configure list-profiles 2>/dev/null; echo fim)
  check "saída de várias linhas sem \\r" sem_cr "$X"
else
  ok "aws não instalado neste runner (pulado)"
fi

step "Caminhos de host para .exe nativos" "no Git Bash a conversão de caminhos está desligada (MSYS_NO_PATHCONV=1)"
if [ -n "$IS_WINDOWS" ]; then
  check "ROOT_HOST no formato C:/..." bash -c "[[ '$ROOT_HOST' =~ ^[A-Za-z]:/ ]]"
fi
check "git -C \"\$ROOT_HOST\" (git_commit_push)" git -C "$ROOT_HOST" rev-parse --is-inside-work-tree
if type -P terraform >/dev/null 2>&1; then
  WS_ANTES=$(terraform -chdir="$ROOT_HOST/terraform" workspace show 2>/dev/null || echo default)   # devolvido no fim
  check "terraform -chdir=\"\$ROOT_HOST/terraform\" init (use_site)" \
    bash -c "terraform -chdir='$ROOT_HOST/terraform' init -backend=false -input=false >/dev/null"
  check "terraform workspace select -or-create (use_site)" \
    bash -c "terraform -chdir='$ROOT_HOST/terraform' workspace select -or-create portabilidade-ci >/dev/null"
  terraform -chdir="$ROOT_HOST/terraform" workspace select "$WS_ANTES" >/dev/null 2>&1 || true
  terraform -chdir="$ROOT_HOST/terraform" workspace delete portabilidade-ci >/dev/null 2>&1 || true
else
  ok "terraform não instalado neste runner (pulado)"
fi
X=$(awk -F'"' '/^region/{print $2}' "$ROOT_HOST/terraform/environments/primary.tfvars")
check "awk lê tfvars por \$ROOT_HOST (fallback de região do use_site): [$X]" test "$X" = us-east-1
X=$(hostpath "$ROOT_DIR/scripts")
check "hostpath devolve caminho existente" test -d "$X"

step "YAML do GitOps e GHCR" "a Etapa 4 lê as imagens do overlay e testa o pull anônimo com curl + python3"
IMAGES=$(overlay_images)
N=$(printf '%s\n' "$IMAGES" | grep -c '^ghcr\.io/' || true)
check "3 imagens lidas do overlay" test "$N" = 3
check "imagens sem \\r" sem_cr "$IMAGES"
for IMG in $IMAGES; do
  RC=0; ghcr_anon_pull "$IMG" || RC=$?   # 1 = token negado (privado) | 2 = manifest (tag ou curl -o) falhou
  check "pull anônimo: ${IMG##*/} (rc=$RC)" test "$RC" = 0
done
X=$(curl -s -o /dev/null -w '%{http_code}' https://ghcr.io/v2/)
check "curl -o /dev/null -w http_code (smoke tests e caos): [$X]" test "$X" = 401
X=$(awk '/repoURL:/{print $2; exit}' gitops/argocd/root-app.yaml)
check "repoURL do root-app: [$X]" test "$X" = https://github.com/chavatta/PostTech-Challenge-5.git

echo
[ "$FALHAS" -eq 0 ] || fail "$FALHAS verificação(ões) de portabilidade falharam em $(uname -s)"
ok "portabilidade OK em $(uname -s)"
