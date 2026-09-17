# PostTech Challenge 5 — SolidaryTech (Hackathon DCLT Fase 5)

Plataforma da ONG SolidaryTech operada com práticas de **SRE, FinOps, Segurança/DR e ITSM/AIOps**
sobre a fundação DevOps das fases 1 a 4 (Docker, Kubernetes/EKS, Terraform, CI/CD DevSecOps, GitOps, Observabilidade/APM).

> Regra do projeto: **nada é feito à mão**. Todo passo tem um script em `scripts/` com o motivo de cada comando
> e uma seção correspondente em [`docs/ROTEIRO.md`](docs/ROTEIRO.md), que é o guia usado na gravação do vídeo.

## Estrutura

```
services/            código dos 3 microsserviços + Dockerfiles otimizados
  ngo-service/       Flask + PostgreSQL        (porta 8081)
  donation-service/  Go + PostgreSQL + SQS     (porta 8082)  <- HOT PATH
  volunteer-service/ Flask + DynamoDB          (porta 8083)
local/               docker-compose para rodar tudo localmente (Postgres + LocalStack)
scripts/             scripts numerados por etapa, com explicação de cada passo
docs/                ROTEIRO.md (passo a passo p/ vídeo), PCN, SLOs, FinOps, ITSM
terraform/           (Etapa 2) infraestrutura como código com tags FinOps
.github/workflows/   (Etapa 3) pipelines CI/CD DevSecOps
gitops/              (Etapa 4) manifests Kubernetes consumidos pelo ArgoCD
```

## Etapas

| # | Etapa | Status |
|---|-------|--------|
| 1 | Containerização + ambiente local | ✅ |
| 2 | Terraform (VPC, EKS, RDS, SQS, DynamoDB) com tags FinOps | ✅ código validado, apply pendente de credenciais |
| 3 | CI/CD DevSecOps (GitHub Actions + Trivy + Sonar) | ⏳ |
| 4 | GitOps com ArgoCD + rightsizing | ⏳ |
| 5 | Observabilidade (Prometheus/Grafana/Loki) + New Relic APM | ⏳ |
| 6 | SRE: SLI/SLO, Error Budget, dashboard | ⏳ |
| 7 | FinOps: forecast e otimizações | ⏳ |
| 8 | DR: Velero + PCN (RTO/RPO) | ⏳ |
| 9 | ITSM/AIOps + relatório final | ⏳ |

## Início rápido (Etapa 1)

```bash
scripts/00-preflight.sh     # confere ferramentas
scripts/01-local-up.sh      # build + sobe local + smoke test
scripts/01-local-down.sh    # limpa tudo
```

## Ambiente

- Cloud: AWS Academy Learner Lab (`LabRole`), região `us-east-1`.
- APM: New Relic (Applied Intelligence para AIOps).
- Código-base original: https://github.com/dougls/hackathon-DCLT
