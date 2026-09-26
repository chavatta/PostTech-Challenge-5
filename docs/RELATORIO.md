# Relatório de Entrega — Hackathon DCLT Fase 5 — SolidaryTech

> Modelo do PDF final. Preencher os campos entre `<...>`, inserir os prints indicados e exportar para PDF
> (VS Code "Markdown PDF", ou `pandoc RELATORIO.md -o RELATORIO.pdf`).

## 1. Identificação

| Nome | RM | GitHub |
|---|---|---|
| <nome 1> | <RM> | <@user> |
| <nome 2> | <RM> | <@user> |
| <nome 3> | <RM> | <@user> |

- **Repositório:** https://github.com/chavatta/PostTech-Challenge-5
- **Vídeo:** <link>
- **Cloud:** AWS (Academy Learner Lab) — região primária `us-east-1`, DR `us-west-2`
- **APM:** New Relic

## 2. Arquitetura

<print: diagrama de arquitetura (VPC, EKS, RDS, SQS, DynamoDB, NLB, ArgoCD, Prometheus/Grafana/Loki, New Relic, Velero→S3)>

Resumo: três microsserviços em EKS, provisionado 100 % por Terraform com política de tags FinOps; entrega por
GitHub Actions (DevSecOps) e ArgoCD (GitOps); observabilidade com Prometheus/Grafana/Loki e APM/AIOps no New Relic;
DR com Velero (opção A) e Terraform warm standby (opção B).

## 3. Fundação DevOps (requisito 0)

| Item | Evidência |
|---|---|
| Dockerfiles otimizados | `services/*/Dockerfile` — <print `docker images` (donation 22 MB distroless)> |
| Kubernetes (EKS) | <print `kubectl get nodes` e `kubectl -n solidarytech get pods`> |
| Terraform | <print `terraform apply` "Apply complete"> |
| CI/CD DevSecOps | <print workflow verde + relatório Trivy com CVEs bloqueadas> |
| GitOps (ArgoCD) | <print UI do ArgoCD com Applications Synced/Healthy> |
| Observabilidade + APM | <print Grafana; print New Relic Distributed Tracing com span Postgres/SQS> |

## 4. Seção SRE — donation-service

Definição formal (resumo de `docs/SRE.md`):

| SLI | SLO (30 d) | SLA (ONGs) |
|---|---|---|
| Disponibilidade (sem 5xx) | 99,9 % | 99,5 % |
| Latência (< 250 ms) | 99,0 % | 95 % < 1 s |

- <print dashboard "SRE — donation-service SLOs & Error Budget" com os 4 stats>
- <print Prometheus → Alerts com as regras `donation-service.slo-alerts`>
- **MTTR demonstrado:** teste `06-sre-chaos.sh errors` (tabela `donations` renomeada no RDS) → detecção pelo alerta
  (MTTD) em <X> s, correção pelo runbook em <Y> s, **MTTR <X+Y> s** (linha "MTTR ... = detecção ... + correção ..." do script).
  <print do alerta disparando e resolvendo>
- Como a stack reduz o MTTR: tabela em `docs/SRE.md` §6.

## 5. Seção FinOps

- **Tagging:** `default_tags` no provider Terraform. <print `07-finops-report.sh tags`: recursos do Terraform sem
  `Project` = nenhum; recursos criados em runtime pelo EKS/K8s listados à parte, com o dono> <print tags de um recurso no console>
- **Rightsizing:** tabela de requests/limits e uso medido:

| Serviço | CPU req/lim | Mem req/lim | Uso medido (kubectl top) |
|---|---|---|---|
| donation-service | 50m / 300m | 32Mi / 96Mi | <..> |
| ngo-service | 50m / 250m | 96Mi / 192Mi | <..> |
| volunteer-service | 50m / 250m | 96Mi / 192Mi | <..> |

- **Forecast:** ≈ US$ 210/mês (tabela completa em `docs/FINOPS.md` §3).
- **Recomendação principal:** Spot Instances no node group (≈ US$ 40/mês, 70 % do EC2), viável porque os serviços
  são stateless com HPA/PDB. Outras: Graviton, Savings Plan, VPC endpoints.

## 6. Seção Segurança e DR

- **PCN** (`docs/PCN.md`): RPO doações **5 min** (PITR RDS), RTO **60 min** (regional), RTO namespace **30 min** (Velero).
- **Estratégia:** Opção A Velero (backup horário → S3 versionado) **e** Opção B Terraform warm standby (`environments/dr.tfvars`).
- <print `velero backup get` + objetos no S3>
- <print do restore: ArgoCD pausado, namespace apagado e recuperado pelo Velero (label `velero.io/restore-name`) — RTO medido <Z> s>
- <print `terraform plan` do workspace `dr`>
- Segurança: gates DevSecOps, Pod Security `restricted`, NetworkPolicy, non-root/read-only FS, secrets via SSM (`docs/SEGURANCA.md`).

## 7. Seção ITSM / AIOps

- Ciclo de vida do incidente: <imagem do diagrama de `docs/ITSM.md`>
- Matriz de severidade e runbooks: `docs/ITSM.md`.
- AIOps: <print New Relic Anomaly detection configurada> <print Issue correlacionado durante o teste de caos>
- <print Service Levels no New Relic>

## 8. Conclusão

<parágrafo: o que foi entregue, principais aprendizados, próximos passos (IRSA, KMS, endpoint privado, Spot)>
