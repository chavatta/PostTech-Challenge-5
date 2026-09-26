#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 04 - Etapa 4: GitOps. Único momento em que se usa kubectl "diretamente", e só para bootstrap:
#   1) Secrets (nunca vão para o git): credenciais do banco (lidas do SSM) e imagePullSecret opcional
#   2) ConfigMap app-config renderizado a partir dos outputs do Terraform e COMMITADO (GitOps)
#   3) Instala o ArgoCD e aplica o AppProject + a Application raiz (app of apps)
# A partir daqui, todo deploy acontece via commit na main.
# Pré-requisitos: scripts/02-terraform-apply.sh concluído; kubeconfig apontando para o cluster.
# ------------------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"
"$ROOT_DIR/scripts/aws-login-check.sh"
# falha logo no início, antes de mexer em qualquer coisa: o ArgoCD instala o New Relic nesta etapa e ele precisa da licença
[ -n "${NEW_RELIC_LICENSE_KEY:-}" ] || fail "exporte NEW_RELIC_LICENSE_KEY antes da Etapa 4 (New Relic -> API keys -> INGEST - LICENSE)"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"

step "Lendo outputs do Terraform" "os manifests não têm valores hardcoded: tudo vem do IaC"
cd terraform; terraform workspace select primary >/dev/null
REGION=$(terraform output -raw region)
SQS_URL=$(terraform output -raw sqs_queue_url)
SSM_NGO=$(terraform output -json db_url_ssm_parameters | python3 -c 'import sys,json;print(json.load(sys.stdin)["ngo_db"])')
SSM_DON=$(terraform output -json db_url_ssm_parameters | python3 -c 'import sys,json;print(json.load(sys.stdin)["donation_db"])')
cd "$ROOT_DIR"
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"   # todos os `aws` abaixo usam a região do IaC
kubectl get nodes >/dev/null || fail "kubectl não alcança o cluster (rode: $(cd terraform && terraform output -raw kubeconfig_command))"
ok "região=$REGION fila=$SQS_URL"

step "Namespace + Secret db-credentials (a partir do SSM SecureString)" \
     "a senha do RDS nunca passa pelo git nem por variável de ambiente do dev; sai do SSM direto para o Secret"
kubectl create namespace solidarytech --dry-run=client -o yaml | kubectl apply -f - >/dev/null
NGO_URL=$(aws ssm get-parameter --name "$SSM_NGO" --with-decryption --query Parameter.Value --output text) || fail "não consegui ler $SSM_NGO no SSM"
DON_URL=$(aws ssm get-parameter --name "$SSM_DON" --with-decryption --query Parameter.Value --output text) || fail "não consegui ler $SSM_DON no SSM"
[ -n "$NGO_URL" ] && [ -n "$DON_URL" ] || fail "DATABASE_URL vazia no SSM: o terraform apply terminou?"
kubectl -n solidarytech create secret generic db-credentials \
  --from-literal=ngo_db_url="$NGO_URL" --from-literal=donation_db_url="$DON_URL" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset NGO_URL DON_URL
ok "secret db-credentials criado"

step "Secret newrelic-license (namespaces solidarytech e newrelic)" \
     "o ArgoCD instala o New Relic nesta etapa; a licença precisa existir antes, senão o nri-bundle não sobe. Vem do shell, nunca do git"
ensure_newrelic_secret
ok "secret newrelic-license criado"

step "imagePullSecret para o GHCR (opcional)" \
     "só é necessário se os pacotes GHCR continuarem privados; com token sem read:packages, pula"
if gh auth status 2>/dev/null | grep -q "read:packages"; then
  kubectl -n solidarytech create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io --docker-username="$(gh api user -q .login)" --docker-password="$(gh auth token)" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n solidarytech patch serviceaccount default -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}' >/dev/null
  ok "imagePullSecret ghcr-pull configurado"
else
  ok "pulado (pacotes GHCR devem estar públicos — ver ROTEIRO 3.5)"
fi

step "Renderizando gitops/overlays/production/app-config.yaml e commitando" \
     "configuração não sensível vive no git (GitOps); o ArgoCD é quem aplica"
cat > gitops/overlays/production/app-config.yaml <<EOC
# Gerado por scripts/04-bootstrap-cluster.sh a partir dos outputs do Terraform (valores não sensíveis).
# Segredos (DATABASE_URL, licença New Relic) NÃO ficam aqui: são Secrets criados pelo script.
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: solidarytech
data:
  AWS_REGION: $REGION
  AWS_SQS_URL: "$SQS_URL"
  AWS_DYNAMODB_TABLE: SolidaryTechVolunteers
  NEW_RELIC_DISTRIBUTED_TRACING_ENABLED: "true"
  NEW_RELIC_LOG: stdout
  NEW_RELIC_LOG_LEVEL: info
EOC
git add gitops/overlays/production/app-config.yaml
git diff --cached --quiet || { git commit -q -m "gitops: app-config renderizado do Terraform (site primary)"; git push -q origin main; }
ok "app-config no git"

step "Instalando ArgoCD ($ARGOCD_VERSION)" "ferramenta de GitOps: observa o repositório e converge o cluster para o que está no git"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# --server-side: o CRD applicationsets.argoproj.io excede o limite de 256 KB da annotation last-applied do apply client-side
kubectl apply -n argocd --server-side --force-conflicts -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml" >/dev/null
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
ok "ArgoCD no ar"

step "Acesso do ArgoCD ao repositório privado (HTTPS + token de quem roda o script)" \
     "funciona para qualquer contribuidor: basta ter leitura no repo (deploy key exigiria ser o dono)"
# URL do repo vem do próprio manifest (fonte única de verdade), não de um valor fixo no script
REPO_URL=$(awk '/repoURL:/{print $2; exit}' gitops/argocd/root-app.yaml)
REPO=${REPO_URL#https://github.com/}; REPO=${REPO%.git}
# ARGOCD_REPO_TOKEN opcional: permite usar um token dedicado (ex.: PAT só leitura) em vez do token do gh
TOKEN="${ARGOCD_REPO_TOKEN:-$(gh auth token 2>/dev/null || true)}"
[ -n "$TOKEN" ] || fail "sem token do GitHub: rode 'gh auth login' (ou exporte ARGOCD_REPO_TOKEN)"
GH_USER=$(GH_TOKEN="$TOKEN" gh api user --jq .login 2>/dev/null) || fail "token do GitHub inválido"
GH_TOKEN="$TOKEN" gh api "repos/$REPO" --jq .full_name >/dev/null 2>&1 \
  || fail "a conta '$GH_USER' não enxerga $REPO: peça acesso de colaborador ou troque com 'gh auth switch'"
kubectl -n argocd create secret generic repo-posttech \
  --from-literal=type=git --from-literal=url="$REPO_URL" \
  --from-literal=username="$GH_USER" --from-literal=password="$TOKEN" --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | kubectl apply -f - >/dev/null
unset TOKEN
ok "repositório registrado no ArgoCD"

step "AppProject + Application raiz (app of apps)" "último kubectl apply do projeto; daqui em diante é só git"
kubectl apply -f gitops/argocd/project.yaml >/dev/null
kubectl apply -f gitops/argocd/root-app.yaml >/dev/null
ok "root app aplicada; ArgoCD vai criar as demais Applications"

step "Aguardando sincronização (ingress, metrics-server, prometheus, loki, newrelic, apps...) ~5-8 min" \
     "sync waves: infraestrutura primeiro, apps por último"
EXPECTED=$(( $(ls gitops/argocd/apps/*.yaml | wc -l) + 1 ))   # root + um Application por arquivo
for i in $(seq 1 60); do
  read -r TOTAL HEALTHY < <(kubectl -n argocd get applications -o json | python3 -c '
import sys,json
a=json.load(sys.stdin)["items"]
ok=sum(1 for x in a if x.get("status",{}).get("health",{}).get("status")=="Healthy" and x.get("status",{}).get("sync",{}).get("status")=="Synced")
print(len(a), ok)')
  printf "\r    %s/%s applications Healthy+Synced" "$HEALTHY" "$TOTAL"
  [ "$TOTAL" -ge "$EXPECTED" ] && [ "$HEALTHY" -eq "$TOTAL" ] && break
  sleep 10
done; echo
kubectl -n argocd get applications
[ "$TOTAL" -ge "$EXPECTED" ] && [ "$HEALTHY" -eq "$TOTAL" ] \
  || fail "nem todos os Applications ficaram Healthy+Synced em 10 min (veja acima: kubectl -n argocd describe application <nome>)"
[ "$HEALTHY" -eq "$TOTAL" ] || printf '\033[1;33m    ! nem todos ficaram Healthy em 10 min; veja acima (newrelic Degraded/Progressing é esperado até a Etapa 5)\033[0m\n'

step "Smoke test via Load Balancer" "prova ponta a ponta: NLB -> ingress-nginx -> pods -> RDS/SQS/DynamoDB"
LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "    URL: http://$LB"
for i in $(seq 1 30); do curl -fsS "http://$LB/health" >/dev/null 2>&1 && break; sleep 10; done
curl -fsS "http://$LB/health" && echo
NGO_ID=$(curl -fsS -X POST "http://$LB/ngos" -H 'Content-Type: application/json' \
  -d '{"name":"ONG GitOps","email":"gitops@solidarytech.org","cause":"Tecnologia","city":"São Paulo"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -fsS -X POST "http://$LB/donations" -H 'Content-Type: application/json' -d "{\"ngo_id\":$NGO_ID,\"amount\":99.9,\"donor_name\":\"Demo\"}" && echo
curl -fsS -X POST "http://$LB/volunteers" -H 'Content-Type: application/json' -d "{\"name\":\"Vol Demo\",\"email\":\"vol@demo.org\",\"ngo_id\":$NGO_ID}" && echo
ok "fluxo completo funcionando em produção"

step "Acesso à UI do ArgoCD" "para o vídeo: mostrar as Applications e o histórico de sync"
echo "    senha admin: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "    kubectl -n argocd port-forward svc/argocd-server 8080:443   ->  https://localhost:8080 (user: admin)"
