# Roteiro do vídeo (≤ 20 min)

Gravar no **ambiente 2**, do zero, seguindo `docs/ROTEIRO.md`. Deixar a infraestrutura já provisionada **antes**
de gravar (o `terraform apply` leva 20 min); mostrar o apply em timelapse ou o `plan` ao vivo.

| Tempo | Bloco | O que mostrar | Fala-chave |
|---|---|---|---|
| 0:00–2:00 | **Abertura / pitch** | Slide: SolidaryTech, problema (picos após TV), 4 exigências da diretoria | "Não basta fazer deploy; precisamos provar resiliência, custo e resposta a incidente." |
| 2:00–4:00 | **Arquitetura** | Diagrama; explicar hot path e escolhas (EKS, RDS, SQS, DynamoDB, GHCR, ArgoCD, New Relic) | "Tudo nasce do git. Nada é clicado." |
| 4:00–6:00 | **Fundação: IaC + tags** | `terraform plan`/apply (timelapse), `providers.tf` default_tags, `07-finops-report.sh tags` | "Nada que o Terraform cria nasce sem tag de custo; o que o EKS cria sozinho aparece à parte, com o dono." |
| 6:00–8:00 | **CI/CD DevSecOps** | Actions: matriz, Trivy bloqueando CVE (PR de demonstração), push GHCR | "O que foi testado é exatamente o que vai para o cluster: tag = SHA." |
| 8:00–10:00 | **GitOps** | ArgoCD UI; `04-gitops-demo.sh selfheal` (patch manual no HPA revertido pelo selfHeal); rollout por commit | "O cluster converge para o git, não o contrário." |
| 10:00–12:30 | **Observabilidade + SRE** | Grafana dashboard SLO/error budget; `06-sre-chaos.sh errors` → alerta FIRING → runbook → recuperação; MTTD e MTTR medidos | "SLO 99,9 %: 43 minutos de erro por mês. O alerta dispara pela velocidade de consumo do budget." |
| 12:30–14:30 | **APM + AIOps** | New Relic: trace distribuído (Postgres + SQS), Anomaly detection, Issue correlacionado, Service Levels | "Detecção preditiva, não só reativa." |
| 14:30–16:30 | **FinOps** | Rightsizing (`kubectl top` vs requests), forecast, recomendação Spot | "≈ US$ 210/mês; Spot corta 40." |
| 16:30–19:00 | **DR / PCN** | `08-dr-drill.sh backup` → S3; `restore` com o ArgoCD pausado, apagando o namespace e voltando pelo Velero (RTO medido); `terraform plan` do workspace dr; RPO/RTO do PCN | "Se a região cair: 1 hora para voltar, 5 minutos de doações no pior caso." |
| 19:00–20:00 | **ITSM + fechamento** | Diagrama do ciclo de incidente; post-mortem; próximos passos | "Entrega: código, evidências, plano. Obrigado." |

Dicas:
- `PAUSE=1` nos scripts para narrar antes de cada passo. Exceções de propósito: no `06-sre-chaos.sh errors` nada
  pausa entre a injeção e a recuperação (a pausa entraria no MTTD/MTTR), e no `selfheal` a observação começa logo
  após o patch (o ArgoCD reverte em segundos).
- Deixar port-forwards do Grafana/ArgoCD abertos em abas antes de gravar.
- Preparar o PR "vulnerável" (ex.: voltar `Flask==2.2.2`) com antecedência para o bloco de DevSecOps.
- Gravar o `06-sre-chaos.sh errors` com o Grafana e o New Relic lado a lado.
