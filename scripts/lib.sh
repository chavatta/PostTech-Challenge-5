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
# type -P: só executável no PATH. `command -v` acharia as funções de mesmo nome definidas abaixo (python3, aws).
need() { type -P "$1" >/dev/null 2>&1 || fail "ferramenta '$1' não encontrada. $2"; }

# --- Portabilidade (macOS / Linux / Windows via Git Bash ou WSL, qualquer Docker) ---
# No Git Bash (MSYS) o shell converte caminhos POSIX em argumentos ("/src" vira "C:\Program Files\Git\src").
# MSYS_NO_PATHCONV=1 desliga isso (MSYS2_ARG_CONV_EXCL é o equivalente no shell do MSYS2 puro), e hostpath() converte
# o lado do host para o formato que os .exe nativos entendem.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'; IS_WINDOWS=1 ;; *) IS_WINDOWS= ;; esac
hostpath() {  # caminho absoluto do host pronto para "-v <host>:<container>" e para .exe nativos
  if [ -n "$IS_WINDOWS" ] && command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
# Com a conversão desligada, /c/Users/... chegaria cru a terraform.exe/git.exe/docker.exe ("cannot find the path").
# ROOT_HOST = C:/Users/... no Git Bash e igual a ROOT_DIR no resto: use-o em todo caminho de host passado a um .exe.
ROOT_HOST=$(hostpath "$ROOT_DIR")

# Python 3 (lê o JSON das CLIs). No Windows 'python3' costuma ser o alias da Microsoft Store, que não executa nada:
# o teste roda o interpretador de verdade. python3() sombreia o comando em todos os scripts, sem mudar as chamadas.
PY=()
for _c in python3 python "py -3"; do
  if command $_c -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then read -ra PY <<<"$_c"; break; fi
done; unset _c
python3() {
  if [ ${#PY[@]} -eq 0 ]; then   # na stderr: quase toda chamada está dentro de $(...), que engoliria a mensagem
    printf '\033[1;31m    ✖ Python 3.8+ não encontrado. Windows: winget install -e --id Python.Python.3.12 e desligue os aliases python.exe/python3.exe em Configurações > Aplicativos > Configurações avançadas > Aliases de execução. Ubuntu/WSL: sudo apt install -y python3\033[0m\n' >&2
    return 127
  fi
  if [ -n "$IS_WINDOWS" ]; then
    # python.exe escreve \r\n (em $(...) o \r sobra no fim do valor) e usa cp1252 quando a saída é um pipe
    PYTHONUTF8=1 PYTHONIOENCODING=utf-8 command "${PY[@]}" "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"
  fi
  command "${PY[@]}" "$@"
}
# AWS CLI v2 é Python congelado: no Windows também escreve \r\n (URL de fila, nome de bucket, account id com \r).
# kubectl/terraform/gh/velero são Go e escrevem só LF: sem wrapper (o pipe quebraria port-forward &, run -i e prompts).
if [ -n "$IS_WINDOWS" ] && type -P aws >/dev/null 2>&1; then
  aws() { command aws "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
fi
# O curl do Git Bash (/mingw64/bin/curl.exe) é nativo: com a conversão desligada, "-o /dev/null" vira um arquivo
# \dev\null inexistente e o curl falha (visto no CI windows-latest). NUL é o dispositivo nulo do Windows.
if [ -n "$IS_WINDOWS" ] && [ "$(type -P curl)" != /usr/bin/curl ]; then
  curl() {
    local a=() x
    for x in "$@"; do [ "$x" = /dev/null ] && x=NUL; a+=("$x"); done
    command curl "${a[@]}"
  }
fi
# Docker Compose v2 é obrigatório ("docker compose"). Docker Desktop, Colima, Rancher, OrbStack e Podman Desktop servem.
compose() { docker compose "$@"; }

# --- Bucket do Velero x SCP do AWS Academy ---
# Algumas contas do Academy têm SCP que nega s3:GetBucketObjectLockConfiguration; o provider AWS chama essa API
# ao ler qualquer aws_s3_bucket e falha. velero_bucket_tf_allowed testa a permissão num bucket real
# (o próprio, se já existir; senão um bucket temporário) e responde se o Terraform pode gerenciá-lo.
velero_bucket_tf_allowed() {  # $1 = nome do bucket do Velero; retorno 0 = pode, 1 = SCP nega
  local b="$1" probe="" err rc=0
  if ! aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
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
  aws s3api head-bucket --bucket "$1" >/dev/null 2>&1 || s3_create_bucket "$1"
  aws s3api put-bucket-tagging --bucket "$1" --tagging 'TagSet=[{Key=Project,Value=SolidaryTech},{Key=Environment,Value=Production},{Key=CostCenter,Value=NGO-Core},{Key=ManagedBy,Value=Script}]' >/dev/null
  aws s3api put-bucket-versioning --bucket "$1" --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-bucket-encryption --bucket "$1" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
  aws s3api put-public-access-block --bucket "$1" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null
  aws s3api put-bucket-lifecycle-configuration --bucket "$1" --lifecycle-configuration '{"Rules":[{"ID":"expire-old-backups","Status":"Enabled","Filter":{},"Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":7}}]}' >/dev/null
}

# --- Site (primary|dr): workspace do Terraform + região + contexto do kubectl ---
# `02-terraform-apply.sh dr` deixa o workspace em dr e o kubectl no cluster do DR; nenhuma etapa seguinte pode confiar
# no estado corrente. use_site fixa os três de uma vez, de qualquer diretório (terraform -chdir: o cwd não muda).
# Workspace inexistente aborta (fail). Cluster inexistente só retorna 1 com aviso: quem aceita isso (destroy) usa `use_site x || ...`;
# nos demais scripts o set -e interrompe ali.
use_site() {  # $1 = primary|dr
  local site="${1:-}" tf="$ROOT_HOST/terraform" region cluster
  case "$site" in primary|dr) ;; *) fail "use_site: site inválido '$site' (use primary ou dr)" ;; esac
  terraform -chdir="$tf" workspace select "$site" >/dev/null \
    || fail "workspace terraform '$site' não existe: rode scripts/02-terraform-apply.sh $site"
  # sem state (nunca aplicado ou já destruído) o output sai vazio (e com rc 0): cai no tfvars do site, a mesma fonte do Terraform
  region=$(terraform -chdir="$tf" output -raw region 2>/dev/null || true)
  [ -n "$region" ] || region=$(awk -F'"' '/^region/{print $2}' "$tf/environments/$site.tfvars" 2>/dev/null || true)
  [ -n "$region" ] || fail "região do site $site não encontrada (nem output region, nem environments/$site.tfvars)"
  export REGION="$region" AWS_REGION="$region" AWS_DEFAULT_REGION="$region"
  cluster=$(terraform -chdir="$tf" output -raw cluster_name 2>/dev/null || true)
  # --alias estável: o contexto aparece como solidarytech-<site> (e não como o ARN), igual em todos os scripts e no vídeo
  if [ -z "$cluster" ] || ! aws eks update-kubeconfig --region "$region" --name "$cluster" --alias "solidarytech-$site" >/dev/null; then
    printf '\033[1;33m    ! cluster do site %s (%s) não encontrado (ainda não subiu ou já foi destruído): kubectl segue no contexto anterior\033[0m\n' \
      "$site" "$region" >&2
    return 1
  fi
}

# --- Commit + push na main (GitOps) ---
# O job update-gitops do CI commita a nova tag na main ~3 min depois de cada push: sem pull --rebase, o push seguinte do
# roteiro é rejeitado (fetch first). Idempotente: sem mudança não commita, mas SEMPRE sincroniza e faz push, para entregar
# também um commit que ficou só local numa execução anterior que falhou no push.
git_commit_push() {  # $1 = mensagem | $2... = caminhos (relativos à raiz do repo)
  local msg="$1" r="$ROOT_HOST" i out; shift
  # o ArgoCD observa a main; commitar em outra branch e dar push na main não entregaria nada
  [ "$(git -C "$r" branch --show-current)" = main ] || fail "git_commit_push: faça checkout da main (o ArgoCD observa a main)"
  git -C "$r" add -- "$@"
  # pathspec no commit: só estes arquivos entram, mesmo que haja outras coisas no stage
  git -C "$r" diff --cached --quiet -- "$@" || git -C "$r" commit -q -m "$msg" -- "$@"
  for i in 1 2 3; do
    # --autostash: alteração local não commitada (de outro arquivo) não pode travar o rebase; saída só aparece se falhar
    out=$(GIT_TERMINAL_PROMPT=0 git -C "$r" pull -q --rebase --autostash origin main 2>&1) \
      || { printf '%s\n' "$out" >&2; git -C "$r" rebase --abort >/dev/null 2>&1 || true
           fail "git pull --rebase falhou (conflito ou rede): resolva com 'git status' e rode de novo"; }
    out=$(GIT_TERMINAL_PROMPT=0 git -C "$r" push -q origin main 2>&1) && return 0
    case "$out" in  # só repete quando a main andou no remoto; recusa por permissão/proteção de branch falha na hora
      *"(fetch first)"*|*"(non-fast-forward)"*|*"cannot lock ref"*|*"failed to update ref"*|*"incorrect old value"*)
        printf '    push rejeitado: o bot do CI commitou na main entre o pull e o push; sincronizando de novo (%s/3)\n' "$i" ;;
      *) printf '%s\n' "$out" >&2; fail "git push falhou por outro motivo (acesso de escrita/rede): veja acima" ;;
    esac
  done
  fail "git push rejeitado 3 vezes seguidas: confira 'git log origin/main' e rode de novo"
}

# --- Licença New Relic ---
# Secret criado ANTES de o ArgoCD instalar o nri-bundle (Etapa 4); a Etapa 5 só reaproveita. Idempotente.
ensure_newrelic_secret() {
  [ -n "${NEW_RELIC_LICENSE_KEY:-}" ] || fail "exporte NEW_RELIC_LICENSE_KEY antes de rodar (New Relic -> API keys -> INGEST - LICENSE)"
  local ns
  for ns in solidarytech newrelic; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n "$ns" create secret generic newrelic-license --from-literal=NEW_RELIC_LICENSE_KEY="$NEW_RELIC_LICENSE_KEY" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
}

# --- Imagens do GHCR ---
# pull anônimo = o que o kubelet faz sem imagePullSecret: token anônimo + GET do manifest (index OCI ou Docker v2)
ghcr_anon_pull() {  # $1 = ghcr.io/<dono>/<pacote>:<tag>; 0 = baixa sem credencial | 1 = pacote privado | 2 = tag não existe
  local repo="${1#ghcr.io/}" tag tok
  tag="${repo##*:}"; repo="${repo%:*}"
  tok=$(curl -fs "https://ghcr.io/token?service=ghcr.io&scope=repository:$repo:pull" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])' 2>/dev/null) || return 1
  curl -fs -o /dev/null -H "Authorization: Bearer $tok" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/$repo/manifests/$tag" || return 2
}
overlay_images() {  # imagens ghcr.io do overlay de produção, como <imagem>:<tag> (o CI reescreve a tag a cada build)
  tr -d '\r' < "$ROOT_DIR/gitops/overlays/production/kustomization.yaml" \
    | awk '/^- name:/{if(img)print img":"tag; img=$3; tag="latest"} /^ *newName:/{img=$2} /^ *newTag:/{tag=$2}
           END{if(img)print img":"tag}' | tr -d '"' | grep '^ghcr\.io/' || true
}
