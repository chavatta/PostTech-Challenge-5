# Roteiro de execução — SolidaryTech

Este documento é o **guia de gravação**. Cada etapa lista, na ordem, o comando a executar,
o que ele faz, por que ele existe e o que falar no vídeo. Os scripts em `scripts/` imprimem
o mesmo "o quê / por quê" no terminal, então basta seguir a sequência.

Dica: exporte `PAUSE=1` antes de rodar um script para ele parar antes de cada passo
(`PAUSE=1 scripts/01-local-up.sh`). Útil para narrar com calma durante a gravação.

---

## Etapa 1 — Containerização e ambiente local

**Objetivo:** provar que os três serviços foram containerizados de forma otimizada e funcionam
juntos antes de qualquer gasto em nuvem.

**Requisito do enunciado atendido:** "Docker e Kubernetes: criação de Dockerfiles otimizados para os 3 novos serviços".

### 1.1 Pré-voo

```bash
scripts/00-preflight.sh
```

| | |
|---|---|
| O que faz | Confere docker, git, gh, aws, terraform, kubectl e o daemon do Docker. |
| Por quê | Falha rápida. Descobrir que falta uma ferramenta no meio da gravação custa uma tomada inteira. |
| Falar no vídeo | "Antes de tudo, validamos o ambiente. O projeto não depende de nada instalado à mão além dessas CLIs." |

Os scripts são `bash` e funcionam em **macOS, Linux e Windows (Git Bash ou WSL)** com **qualquer runtime Docker**
(Docker Desktop, Colima, Rancher Desktop, OrbStack, Podman Desktop) que tenha o Compose v2 (`docker compose`).
No Windows, rode sempre pelo Git Bash: `scripts/lib.sh` desliga a conversão de caminhos do MSYS e converte os
mounts com `cygpath`. O scan de imagens usa `docker save` + Trivy em tar, sem depender do `docker.sock`.

### 1.2 O que mudou no código-base original

Tudo que foi alterado em relação ao repositório do professor, e o motivo:

| Arquivo | Mudança | Motivo |
|---|---|---|
| `services/*/Dockerfile` | criados, multi-stage | imagens pequenas, non-root, sem toolchain em runtime |
| `services/*/.dockerignore` | criados | não vazar `.env` nem lixo para a imagem |
| `services/*/requirements.txt` | Flask 2.2→3.0, gunicorn 20→23, boto3 1.26→1.35 | versões antigas têm CVEs que o Trivy reprova (DevSecOps) |
| `services/donation-service/go.mod` + `go.sum` | aws-sdk-go 1.51→1.55; `go.sum` gerado | o repo original não tinha `go.sum`, logo não buildava de forma reproduzível |
| `services/donation-service/main.go` | removidos imports `fmt` e `strconv` não usados | **o código original não compila** (`imported and not used`) |
| `services/donation-service/main.go` | honra `AWS_ENDPOINT_URL` se definida | permite LocalStack em dev; em produção a variável não existe e nada muda |
| `local/` | docker-compose + Postgres + LocalStack | ambiente local completo sem custo AWS |

### 1.3 Subir o ambiente local e testar

```bash
scripts/01-local-up.sh
```

Passo a passo do que o script faz:

1. **`docker compose up -d --build --wait`**
   Builda as 3 imagens e sobe Postgres (com `ngo_db` e `donation_db` criados pelo `local/postgres-init.sh`)
   e LocalStack (com a fila SQS e a tabela DynamoDB criadas pelo `local/localstack-init.sh`).
   *Falar:* "O compose reproduz a topologia de produção: dois bancos relacionais, uma fila e uma tabela NoSQL."

2. **`docker images | grep solidarytech`**
   Mostra o tamanho das imagens.
   *Falar:* "O donation-service usa base distroless: sem shell, sem package manager. Os serviços Python usam python-slim
   e rodam como usuário sem privilégio. Isso é o 'Dockerfile otimizado' do enunciado."

3. **`curl /health` nos 3 serviços**
   *Falar:* "Mesmo endpoint que o Kubernetes vai usar nas probes de liveness e readiness."

4. **POST /ngos → POST /donations → POST /volunteers**
   Exercita Postgres, SQS e DynamoDB em sequência.
   *Falar:* "Fluxo real de negócio: uma ONG se cadastra, recebe uma doação (hot path) e um voluntário se inscreve."

5. **`awslocal sqs receive-message`**
   Prova que a doação gerou um evento assíncrono.
   *Falar:* "O donation-service publica cada doação numa fila. Em produção é o SQS real, criado pelo Terraform."

### 1.4 Limpar

```bash
scripts/01-local-down.sh
```

Remove containers e volumes para a próxima execução partir do zero.

### Evidências para o relatório

- Print do `docker images` com os tamanhos.
- Print do smoke test com os três `201 Created`.
- Print da mensagem SQS recebida.

---

## Etapa 2 — Infraestrutura como Código (Terraform)

**Objetivo:** provisionar 100% do ambiente por código, com política de tags FinOps embutida,
e provar que o mesmo código sobe uma região espelho (DR opção B) com um comando.

**Requisitos do enunciado atendidos:** "IaC: provisionamento de todo o ambiente via Terraform",
"FinOps: Estratégia de Tagging (IaC)", "DR opção B: Terraform modularizado para levantar ambiente espelho".

### 2.1 O que o Terraform cria

| Módulo | Recursos | Decisão / motivo |
|---|---|---|
| `network` | VPC, 2 subnets públicas, 2 privadas, IGW, **1** NAT, route tables | 1 NAT em vez de 2 = metade do custo (~US$ 32/mês). Trade-off FinOps documentado. |
| `eks` | Cluster 1.31, node group t3.medium (2 a 4 nós), add-ons vpc-cni, coredns, kube-proxy, **ebs-csi** | Control plane e nós usam a `LabRole` (Academy não permite criar IAM). EBS CSI é necessário para volumes do Prometheus/Loki. Logs de audit ligados. |
| `data` | RDS Postgres 16 `db.t3.micro` (backup 7 dias + PITR), DynamoDB on-demand com PITR, SQS + DLQ | Backups do RDS definem o RPO das doações. DLQ evita perder eventos de doação. Senha gerada e guardada no SSM (SecureString), nunca no repo. |
| `registry` | 3 repositórios ECR (scan on push, tags imutáveis, lifecycle 10 imagens) + bucket S3 do Velero (versionado, criptografado, expira em 30 dias) | Scan on push = 2ª camada DevSecOps. Lifecycle = FinOps. |
| root | `default_tags` no provider + AWS Budget opcional | **Toda** tag obrigatória (`Project`, `Environment`, `CostCenter`) é aplicada pelo provider: impossível criar recurso sem tag. |

Tags aplicadas em todos os recursos: `Project=SolidaryTech`, `Environment=Production`, `CostCenter=NGO-Core`,
`ManagedBy=Terraform`, `Owner`, `Site=primary|dr`.

### 2.2 Credenciais do lab

```bash
scripts/aws-login-check.sh
```

| | |
|---|---|
| O que faz | Valida `sts get-caller-identity` e confirma que a `LabRole` existe. |
| Por quê | Credenciais do Academy expiram em ~4h. Um apply interrompido por token vencido deixa recursos órfãos. |
| Como obter | Learner Lab → Start Lab → AWS Details → AWS CLI "Show" → colar em `~/.aws/credentials`. |
| Falar no vídeo | "Não existe usuário IAM criado à mão. Usamos a credencial temporária do lab e a LabRole." |

### 2.3 Provisionar

```bash
scripts/02-terraform-apply.sh          # ~20 min
```

Sequência executada pelo script e o que narrar:

1. **`terraform init`** — baixa providers. *"Versões travadas no lock file, build reproduzível."*
2. **`terraform workspace select primary`** — *"Um workspace por site. O DR usa o mesmo código com outro state."*
3. **`terraform fmt -check` + `validate`** — *"Qualidade de IaC entra no pipeline também (Etapa 3)."*
4. **`terraform plan -out`** — *"Revisamos o plano antes de gastar. O apply usa exatamente esse plano."*
5. **`terraform apply`** — enquanto roda (~20 min), mostrar o código: `providers.tf` (default_tags) e `modules/eks/main.tf` (LabRole).
6. **`aws eks update-kubeconfig` + `kubectl get nodes`** — *"Cluster acessível; nenhum passo manual."*
7. **`aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=SolidaryTech`** —
   **evidência FinOps**: lista todos os recursos com a tag. *"É exatamente este filtro que usamos no Cost Explorer."*

### 2.4 DR opção B — região espelho com 1 comando

```bash
scripts/02-terraform-apply.sh dr       # us-west-2, node group menor (warm standby)
```

*"Mesmo código, outro tfvars, outro workspace. Se us-east-1 cair, o ambiente espelho sobe em ~20 min.
Isso é o RTO de infraestrutura que está no PCN."* (No Academy a região secundária pode estar bloqueada;
se estiver, a evidência é o `terraform plan` do workspace `dr`.)

### 2.5 Problemas conhecidos no Academy (vistos no primeiro apply real)

| Sintoma | Causa | O que fazer |
|---|---|---|
| `Error: reading S3 Bucket (...velero...) object lock configuration ... AccessDenied ... explicit deny in a service control policy` | A SCP dessa conta Academy nega `s3:GetBucketObjectLockConfiguration`. O provider AWS chama essa API ao ler qualquer `aws_s3_bucket` e não tolera o erro. Varia entre contas do Academy. | Não precisa fazer nada à mão: rode `scripts/02-terraform-apply.sh` de novo. Antes do plan ele testa a permissão; se a SCP negar, tira o bucket do state (se já estiver lá), cria/ajusta via AWS CLI com as mesmas propriedades do módulo e roda o Terraform com `manage_velero_bucket=false`. |
| `waiting for EKS Add-On (...aws-ebs-csi-driver) create: timeout ... last state: 'CREATING'` | Os pods do driver não ficaram prontos em 20 min. Causa típica: sem IRSA, o driver pega credenciais da LabRole via IMDS; com hop limit 1 a chamada falha e o pod entra em CrashLoop. Também acontece se o add-on é criado antes de vpc-cni/coredns. | O código agora define launch template com hop limit 2, dependência de vpc-cni/coredns e timeout de 30 min. Basta rodar o apply de novo (o aviso "will remove the add-on and create it again" é esperado). Para diagnosticar: `kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-ebs-csi-driver` e `kubectl -n kube-system logs deploy/ebs-csi-controller -c ebs-plugin`. |
| `aws: An error occurred (NoRegion)` em qualquer script | O bloco de credenciais do Learner Lab não inclui região. | Corrigido: `scripts/lib.sh` exporta `AWS_DEFAULT_REGION` (padrão `us-east-1`). |
| `CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long` no bootstrap do ArgoCD | Apply client-side grava o manifesto inteiro numa annotation, e o CRD passa de 256 KB. | Corrigido: `04-bootstrap-cluster.sh` usa `kubectl apply --server-side`. |

Se o `04-bootstrap-cluster.sh` rodou com o erro `NoRegion`, o Secret `db-credentials` foi criado **vazio**.
Rode o script de novo: ele recria o Secret e agora falha explicitamente se o SSM não responder.

### 2.6 Destruir ao final da sessão

```bash
scripts/02-terraform-destroy.sh        # ~15 min
```

*"FinOps na prática: ambiente de lab não fica ligado à toa. Subir de novo custa um comando."*

### Evidências para o relatório

- Print do `terraform apply` com o resumo `Apply complete! Resources: N added`.
- Print do `get-resources` com os ARNs tagueados.
- Print das tags de um recurso no console (ex.: cluster EKS → Tags) mostrando `CostCenter=NGO-Core`.
- Print de `kubectl get nodes`.

---

## Etapa 3 — CI/CD DevSecOps (GitHub Actions)

**Objetivo:** todo commit passa por testes, scans de segurança e build de imagem antes de existir
uma imagem publicada. Nenhuma imagem chega ao cluster sem passar pelos gates.

**Requisito do enunciado atendido:** "CI/CD e DevSecOps: pipelines automatizados contemplando testes,
scans de segurança (SAST/SCA com Trivy/Sonar) e construção da imagem".

### 3.1 O pipeline (`.github/workflows/ci.yml`)

```
 secrets (gitleaks) ──┐
 iac (fmt/validate/trivy config) ──┼──> test [matriz 3 serviços] ──> build [matriz 3 serviços] ──> mirror-ecr (opcional)
 sast (semgrep) ──────┘             lint + unit tests + Trivy SCA    hadolint + build + Trivy image + push GHCR
```

| Job | Ferramentas | Por quê |
|---|---|---|
| `secrets` | gitleaks | segredo commitado é a falha mais comum e mais cara |
| `iac` | terraform fmt/validate + Trivy config | Terraform errado também é vulnerabilidade (SG aberto, bucket público) |
| `sast` | semgrep + ruff (regras bandit) | análise estática do código Python/Go/Dockerfile |
| `sonar` | SonarCloud (liga com `vars.SONAR_ENABLED=true`) | qualidade e cobertura; opcional porque exige conta |
| `test` | pytest + Postgres service container / go test / **Trivy SCA** | testes reais + CVEs nas dependências |
| `build` | hadolint + docker buildx + **Trivy image** + push GHCR | imagem final escaneada antes do push; tag = SHA do commit (imutável) |
| `mirror-ecr` | opcional (`vars.ECR_MIRROR=true` + secrets AWS) | espelha para o ECR do Terraform quando há credencial válida |

**Decisão de registry:** GHCR como registry principal. Motivo: a credencial do AWS Academy expira
a cada ~4h e faria o push para o ECR falhar aleatoriamente. O ECR continua existindo (Terraform) e
recebe espelho quando os secrets são atualizados. Imagens não são sensíveis: pacotes GHCR ficam públicos
para o EKS puxar sem `imagePullSecret`.

### 3.2 O que mudou no código

| Arquivo | Mudança | Motivo |
|---|---|---|
| `services/*/test_app.py`, `main_test.go` | **testes criados** | o repositório original não tinha nenhum teste |
| `services/*/ruff.toml`, `requirements-dev.txt` | lint com regras de segurança (bandit) | SAST no nível do lint |
| `services/*/app.py` | whitespace / newline final | o código original reprovava no lint |
| `services/*/Dockerfile` (Python) | `apt-get upgrade` no estágio final | a tag `python:3.12-slim` vinha com 3 CVEs CRITICAL no SO (perl) com fix disponível; o Trivy bloqueava |
| `donation-service/go.mod` | Go 1.26, `x/crypto` 0.20→0.57, `x/text` 0.14→0.42 | 14 CVEs HIGH em dependências indiretas do pgx; as versões corrigidas exigem Go ≥ 1.26 |
| `.trivyignore` | exceções de IaC documentadas | cada ID tem justificativa em `docs/SEGURANCA.md` |
| `.hadolint.yaml` | regras de pin ignoradas | versões já pinadas nos requirements |

### 3.3 Rodar os gates localmente (shift-left)

```bash
scripts/03-ci-check.sh
```

| | |
|---|---|
| O que faz | Executa em containers exatamente os mesmos gates do pipeline: go test, ruff+pytest, Trivy fs (SCA+IaC) e Trivy image. |
| Por quê | Desenvolvedor descobre o problema antes do push. Pipeline vermelho custa minutos; scan local custa segundos. |
| Falar no vídeo | "Shift-left: o mesmo scanner que bloqueia o merge roda na máquina do dev." |

### 3.4 Ver o pipeline rodando

```bash
git push                      # dispara o workflow
scripts/03-ci-check.sh watch  # acompanha o run no terminal
```

Ou abrir a aba **Actions** do repositório. Para o vídeo, mostrar:

1. A matriz dos 3 serviços rodando em paralelo. Primeiro run real: **3 CRITICAL + 14 HIGH bloqueados**
   pelo Trivy e 3 findings do Semgrep, todos corrigidos ou justificados (ver 3.2 e `docs/SEGURANCA.md`).
   Isso é evidência de que os gates funcionam, vale contar no vídeo.
2. O relatório do Trivy (tabela de CVEs) em um job de `test` e um de `build`.
3. O push para o GHCR com a tag do SHA. *"Tag imutável: o que foi testado é exatamente o que vai para o cluster."*
4. Um PR de teste com uma vulnerabilidade proposital (ex.: `Flask==2.2.2` de volta) sendo **bloqueado** pelo Trivy.
   Esse é o melhor take de DevSecOps.

### 3.5 Visibilidade das imagens no GHCR (uma vez só)

O repositório é privado, então os pacotes GHCR nascem privados. O EKS precisa puxar as imagens.
Duas opções, escolha uma:

- **A (recomendada, mais simples):** tornar os 3 pacotes públicos. GitHub → perfil → Packages →
  `posttech-challenge-5/<serviço>` → Package settings → Change visibility → Public.
  Imagens não contêm segredo algum (variáveis vêm do Kubernetes), então não há risco.
- **B:** manter privado e criar um `imagePullSecret` no cluster. Requer token com `read:packages`:
  `gh auth refresh -s read:packages` e depois o script da Etapa 4 cria o secret automaticamente.

*Falar no vídeo:* "Imagem pública não é problema: ela não carrega configuração nem credencial.
Tudo sensível entra em runtime via Secret do Kubernetes."

### 3.6 Habilitar o SonarCloud (opcional)

1. Criar projeto em sonarcloud.io apontando para o repositório.
2. `gh secret set SONAR_TOKEN` e `gh variable set SONAR_ENABLED --body true`.
3. Criar `sonar-project.properties` com a `organization` e `projectKey` do Sonar.

### Evidências para o relatório

- Print do workflow verde com os jobs.
- Print do Trivy com CVEs encontradas/bloqueadas.
- Print do pacote no GHCR com as tags.
- Print (opcional) do PR bloqueado.

---

## Etapa 4 — GitOps com ArgoCD

**Objetivo:** nenhum `kubectl apply` de aplicação. O cluster converge para o que está em `gitops/`.
**Requisitos atendidos:** "GitOps: entrega contínua via ArgoCD", "Rightsizing: requests e limits nos YAML via GitOps",
"Não haverá deploy manual via kubectl".

### 4.1 Estrutura

| Caminho | Conteúdo |
|---|---|
| `gitops/base/` | manifests dos 3 serviços: Deployment (requests/limits, probes, securityContext restrito, spread entre AZs), Service, HPA, PDB, ServiceMonitor; Ingress; NetworkPolicy; Job PreSync que cria bancos/schemas |
| `gitops/overlays/production/` | kustomize: **tags de imagem** (o CI reescreve com o SHA) + ConfigMap `app-config` (renderizado do Terraform) |
| `gitops/argocd/` | AppProject, Application raiz (**app of apps**) e uma Application por componente com *sync waves* |
| `gitops/platform/` | values dos charts (ingress-nginx, metrics-server, kube-prometheus-stack, loki, newrelic, velero), regras de SLO, dashboard, schedules do Velero |

Elo CI → CD: job `update-gitops` (`.github/workflows/ci.yml`) roda `kustomize edit set image` e commita `[skip ci]`.
O ArgoCD detecta e faz o rollout. Histórico de deploy = `git log gitops/overlays/production`.

### 4.2 Bootstrap (uma vez por cluster)

```bash
scripts/04-bootstrap-cluster.sh      # ~10 min
```

| Passo | Por quê | Falar no vídeo |
|---|---|---|
| Lê outputs do Terraform | zero valor hardcoded | "A URL da fila vem do IaC." |
| Secret `db-credentials` a partir do SSM | senha nunca passa por git nem pelo dev | "SecureString → Secret, direto." |
| Renderiza e **commita** `app-config.yaml` | configuração não sensível é GitOps | |
| Instala ArgoCD + credencial HTTPS do repo | qualquer contribuidor consegue subir o ambiente | "O ArgoCD usa o token de quem roda o script, só para ler o repositório." |
| `kubectl apply` do AppProject e da root app | **último apply manual do projeto** | "Daqui pra frente é só git." |
| Aguarda Applications Healthy; smoke test pelo NLB | prova ponta a ponta | |

> O Application `newrelic` aparece como `Degraded`/`Progressing` ao fim desta etapa, e isso é esperado: os pods do
> nri-bundle precisam do Secret `newrelic-license`, que só é criado na Etapa 5. O script não espera por ele.
> Os 3 serviços sobem normalmente, porque o Secret é `optional` para eles.

### 4.3 Demonstrações

```bash
scripts/04-gitops-demo.sh selfheal      # kubectl scale manual é revertido pelo ArgoCD
scripts/04-gitops-demo.sh rollout       # deploy disparado por commit
scripts/04-gitops-demo.sh rightsizing   # kubectl top vs requests (evidência FinOps)
```

### Evidências
- Print da UI do ArgoCD (Applications Synced/Healthy) e do `git log` com commits `cd: imagens -> <sha>`.
- Print do selfHeal revertendo. Print de `kubectl top` ao lado dos requests.

---

## Etapa 5 — Observabilidade e APM

**Objetivo:** stack completa (Prometheus, Grafana, Loki) via ArgoCD + APM New Relic com distributed tracing.
**Requisito atendido:** "Observabilidade e APM: stack completa rodando e instrumentação no APM com Distributed Tracing".

### 5.1 O que mudou no código
| Arquivo | Mudança | Motivo |
|---|---|---|
| `services/*/app.py`, `requirements.txt` | `prometheus-flask-exporter` (`/metrics`) e agente `newrelic` | Golden Metrics no Prometheus; traces no New Relic |
| `services/*/Dockerfile` (Python) | `newrelic-admin run-program gunicorn --workers 1 --threads 8` | agente APM; 1 worker = métricas consistentes por pod, escala via HPA |
| `donation-service/metrics.go` | middleware `http_requests_total` / `http_request_duration_seconds` | base dos SLIs |
| `donation-service/main.go` | `newrelic.WrapHandleFunc`, `nrawssdk` no SQS, contexto por request | trace: ingress → handler → Postgres → SQS |
| `donation-service/main.go`, `go.mod` | **pgx v4 → v5** com tracer `nrpgx5`; `SetMaxOpenConns(10)` | o integrador `nrpgx` (v4) arrastava `jackc/pgx` v3 com 2 CVEs HIGH; v5 corrige e é a versão suportada |

Sem `NEW_RELIC_LICENSE_KEY` o agente vira no-op: o código é o mesmo em dev e prod.

### 5.2 Ativar o New Relic
```bash
export NEW_RELIC_LICENSE_KEY=<sua INGEST-LICENSE key>   # New Relic → API keys
scripts/05-observability.sh
```
Cria o Secret nos namespaces, reinicia os serviços, força sync do `nri-bundle` e gera 2 min de tráfego.

### 5.3 Mostrar
- Grafana (`port-forward` impresso pelo script) → dashboard "SRE — donation-service SLOs & Error Budget".
- Explore → Loki → `{namespace="solidarytech"}`.
- New Relic → APM → `solidarytech-donation-service` → Distributed tracing → trace de `POST /donations` com spans Postgres e SQS.
- New Relic → Kubernetes cluster explorer (`solidarytech-primary`).

---

## Etapa 6 — SRE: SLO, Error Budget e MTTR

Definições formais: `docs/SRE.md`. Regras: `gitops/platform/slo-rules.yaml`. Dashboard: `gitops/platform/dashboards/`.

```bash
scripts/06-sre-chaos.sh errors   # injeta falha de banco 3 min → alerta burn rate → mitigação pelo runbook → MTTR medido
scripts/06-sre-chaos.sh kill     # mata pods → auto healing sem perder /health
scripts/06-sre-chaos.sh load     # pico → HPA escala
```

| Falar no vídeo |
|---|
| "Dois SLIs das Golden Metrics: disponibilidade 99,9 % e latência 99 % abaixo de 250 ms. Error budget de 43 minutos por mês." |
| "O alerta não olha um limiar fixo: olha a velocidade de consumo do budget em duas janelas. 14× em 1 h acorda alguém; 6× em 6 h abre ticket." |
| "MTTR: detecção em 2 min pelo alerta, diagnóstico pelo trace, correção pelo ArgoCD. Medimos <X> s no teste." |

### Evidências
- Prints do dashboard antes/durante/depois do caos; print do alerta em Prometheus → Alerts; valor do MTTR.

---

## Etapa 7 — FinOps

Documento: `docs/FINOPS.md` (tags, rightsizing, forecast ≈ US$ 210/mês, recomendação Spot).

```bash
scripts/07-finops-report.sh tags    # inventário por tag + auditoria de recursos sem tag
scripts/07-finops-report.sh usage   # kubectl top vs requests/limits
scripts/07-finops-report.sh cost    # Cost Explorer por tag (pode ser negado no Academy)
```

Falar: "Cada recurso carrega Project, Environment e CostCenter porque o provider Terraform injeta as tags.
Rightsizing veio de medição real. Spot nos nós corta 70 % do EC2 sem mudar código."

---

## Etapa 8 — Disaster Recovery e PCN

Documento executivo: `docs/PCN.md` (RPO doações 5 min, RTO regional 60 min).

```bash
scripts/08-dr-setup.sh            # renderiza values do Velero com o bucket do Terraform e commita
scripts/08-dr-drill.sh backup     # backup sob demanda + objetos no S3
scripts/08-dr-drill.sh restore    # APAGA o namespace e restaura; imprime o RTO medido
scripts/08-dr-drill.sh rds        # snapshot RDS + cópia cross-region
scripts/02-terraform-apply.sh dr  # (opção B) sobe o espelho em us-west-2 — ou mostrar só o plan
```

Falar: "Duas camadas: Velero guarda o estado do cluster no S3 a cada hora; o Terraform sobe a região espelho
com um comando. O banco tem PITR de 5 minutos e snapshot copiado para a outra região."

---

## Etapa 9 — ITSM, AIOps e entrega

- `docs/ITSM.md`: ciclo de vida do incidente (diagrama Mermaid), severidades, runbooks, templates.
- `docs/AIOPS.md`: passos no New Relic (Anomaly detection, Decisions, Workflows, Service Levels) e o que gravar.
- `docs/RELATORIO.md`: modelo do PDF com todos os campos e prints exigidos.
- `docs/VIDEO.md`: roteiro de 20 min com tempos e falas.
- `scripts/09-evidencias.sh`: coleta outputs textuais para anexar.

Ordem sugerida de gravação: Etapas 2 (plan), 3, 4, 5, 6, 7, 8, 9 — o roteiro de tempo está em `docs/VIDEO.md`.
Ao final da sessão: `scripts/02-terraform-destroy.sh`.
