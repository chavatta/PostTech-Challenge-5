# PostTech Challenge 5 — SolidaryTech (Hackathon DCLT Fase 5)

Plataforma da ONG SolidaryTech operada com práticas de **SRE, FinOps, Segurança/DR e ITSM/AIOps**
sobre a fundação DevOps das fases 1 a 4 (Docker, Kubernetes/EKS, Terraform, CI/CD DevSecOps, GitOps, Observabilidade/APM).

> Regra do projeto: **nada é feito à mão**. Todo passo tem um script em `scripts/` com o motivo de cada comando
> e uma seção correspondente em [`docs/ROTEIRO.md`](docs/ROTEIRO.md), que é o guia usado na gravação do vídeo.

## Arquitetura em uma frase

Três microsserviços em **EKS** (VPC, RDS PostgreSQL, SQS, DynamoDB via **Terraform** com tags FinOps), imagens
construídas e escaneadas por **GitHub Actions** e publicadas no **GHCR**, entregues por **ArgoCD** (app of apps,
pull-based), observados por **Prometheus/Grafana/Loki** e pelo APM **New Relic** (distributed tracing + AIOps),
com DR por **Velero → S3** e região espelho por Terraform.

```
Doador ─► NLB ─► ingress-nginx ─► donation-service (Go)  ─► RDS + SQS      ◄── HOT PATH (SLO 99,9 %)
                               ├► ngo-service (Flask)     ─► RDS
                               └► volunteer-service (Flask) ─► DynamoDB
GitHub ─► Actions (CI) ─► GHCR ─► commit da tag em gitops/ ─► ArgoCD ─► EKS
```

## Estrutura

```
services/            código dos 3 microsserviços + Dockerfiles otimizados (distroless / slim, non-root)
  ngo-service/       Flask + PostgreSQL        (porta 8081)
  donation-service/  Go + PostgreSQL + SQS     (porta 8082)  <- HOT PATH
  volunteer-service/ Flask + DynamoDB          (porta 8083)
local/               docker-compose para rodar tudo localmente (Postgres + LocalStack)
terraform/           IaC com default_tags FinOps; workspaces primary (us-east-1) e dr (us-west-2)
.github/workflows/   CI DevSecOps (gitleaks, semgrep, hadolint, Trivy fs/config/image) + job update-gitops (CD)
gitops/
  base/              Deployments (requests/limits, probes, PSS restricted), Services, HPA, PDB, NetworkPolicy, Ingress
  overlays/production/ kustomize: tags de imagem (reescritas pelo CI) + ConfigMap gerado do Terraform
  argocd/            AppProject, root app (app of apps) e uma Application por componente com sync waves
  platform/          values dos charts (ingress-nginx, metrics-server, kube-prometheus-stack, loki, newrelic, velero),
                     regras de SLO (PrometheusRule), dashboard Grafana; Schedules do Velero em values/velero.yaml.tpl
                     (só entram na Etapa 8, junto com o bucket real)
scripts/             scripts numerados por etapa (bash; macOS/Linux/Windows-Git Bash, qualquer Docker com Compose v2)
docs/                ROTEIRO, SRE, FINOPS, PCN, ITSM, AIOPS, SEGURANCA, RELATORIO (modelo do PDF), VIDEO (roteiro)
```

## Etapas

| # | Etapa | Status |
|---|-------|--------|
| 1 | Containerização + ambiente local | ✅ |
| 2 | Terraform (VPC, EKS, RDS, SQS, DynamoDB, S3 Velero) com tags FinOps | ✅ validado; `apply` pendente de credenciais do lab |
| 3 | CI/CD DevSecOps (GitHub Actions + Trivy + Semgrep + Sonar opcional) | ✅ verde no GitHub |
| 4 | GitOps com ArgoCD + rightsizing | ✅ manifests validados; bootstrap pendente de cluster |
| 5 | Observabilidade (Prometheus/Grafana/Loki) + New Relic APM | ✅ código instrumentado |
| 6 | SRE: SLI/SLO/SLA, error budget, alertas burn-rate, dashboard | ✅ |
| 7 | FinOps: tagging, rightsizing, forecast, recomendações | ✅ |
| 8 | DR: Velero + Terraform warm standby + PCN (RTO/RPO) | ✅ código + PCN; drill pendente de cluster |
| 9 | ITSM/AIOps + relatório e roteiro do vídeo | ✅ docs; prints e RMs a preencher |

## Sequência de execução

Passo a passo narrado, com o porquê de cada comando, em [`docs/ROTEIRO.md`](docs/ROTEIRO.md).

```bash
scripts/00-preflight.sh                 # ferramentas
scripts/01-local-up.sh                  # build + ambiente local + smoke test
scripts/03-ci-check.sh                  # mesmos gates do pipeline, localmente
scripts/aws-login-check.sh              # credenciais do Learner Lab
scripts/02-terraform-apply.sh           # infra (~20 min)
NEW_RELIC_LICENSE_KEY=... scripts/04-bootstrap-cluster.sh   # ArgoCD + app of apps; último kubectl apply do projeto (~10 min)
scripts/05-newrelic-aiops.sh            # AIOps no New Relic como código (NEW_RELIC_API_KEY + NEW_RELIC_ACCOUNT_ID)
scripts/05-observability.sh             # APM + tráfego para popular dashboards
scripts/06-sre-chaos.sh errors          # quebra o banco → alerta burn-rate FIRING → runbook → MTTD e MTTR
scripts/07-finops-report.sh tags        # evidências FinOps
scripts/08-dr-setup.sh && scripts/08-dr-drill.sh backup && scripts/08-dr-drill.sh restore
scripts/09-evidencias.sh                # coleta outputs para o relatório
scripts/02-terraform-destroy.sh         # fim da sessão
```

## Documentos da entrega

| Documento | Conteúdo |
|---|---|
| [docs/SRE.md](docs/SRE.md) | SLIs, SLOs (99,9 % disponibilidade, 99 % < 250 ms), SLA, política de error budget, alertas, MTTR |
| [docs/FINOPS.md](docs/FINOPS.md) | estratégia de tags, rightsizing, forecast (≈ US$ 210/mês), recomendações (Spot, Graviton, VPC endpoints) |
| [docs/PCN.md](docs/PCN.md) | plano de continuidade: BIA, RPO 5 min / RTO 60 min, opções A (Velero) e B (Terraform), ativação do DR |
| [docs/ITSM.md](docs/ITSM.md) | ciclo de vida do incidente, matriz de severidade, runbooks, templates de comunicação e post-mortem |
| [docs/AIOPS.md](docs/AIOPS.md) | passos no New Relic: anomaly detection, correlação, workflows, service levels |
| [docs/SEGURANCA.md](docs/SEGURANCA.md) | gates DevSecOps, postura de runtime, exceções aceitas por limitação do Academy |
| [docs/RELATORIO.md](docs/RELATORIO.md) | modelo do PDF com todos os campos e prints exigidos |
| [docs/VIDEO.md](docs/VIDEO.md) | roteiro de 20 min com tempos e falas |

## Pendências antes de gravar

- Pacotes GHCR públicos (ou `gh` com `read:packages`) para o cluster puxar as imagens. A Etapa 4 testa o pull
  anônimo e, se os pacotes forem privados sem credencial, para com os links de cada pacote (ver ROTEIRO 3.5).
- Credenciais do Learner Lab ativas para as etapas 2 a 9.
- `NEW_RELIC_LICENSE_KEY` exportada no shell antes da etapa 4 (o ArgoCD já instala o New Relic nela).
- Nomes, RMs, prints e valores medidos (MTTD/MTTR, RTO, `kubectl top`) em `docs/RELATORIO.md`.

## Ambiente

- Cloud: AWS Academy Learner Lab (`LabRole`), região `us-east-1` (DR em `us-west-2`).
- APM: New Relic (Applied Intelligence para AIOps).
- Registry: GHCR (o ECR existe no Terraform como espelho opcional; credenciais do Academy expiram a cada sessão).
- Código-base original: https://github.com/dougls/hackathon-DCLT
