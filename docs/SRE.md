# SRE — SLIs, SLOs, SLA e Error Budget do donation-service

O `donation-service` é o **hot path**: cada requisição que falha é uma doação que pode não acontecer.
Por isso ele recebe os objetivos mais rígidos da plataforma.

## 1. Definições formais

| Termo | Definição usada aqui |
|---|---|
| **SLI** (indicador) | Medição objetiva, calculada a partir das métricas do próprio serviço (`/metrics`) coletadas pelo Prometheus. |
| **SLO** (objetivo) | Meta interna para o SLI em uma janela móvel de **30 dias**. Guia decisões de engenharia. |
| **SLA** (acordo) | Compromisso externo com as ONGs parceiras, propositalmente **mais frouxo** que o SLO para criar margem. |
| **Error budget** | `1 − SLO`. Quanto de falha é aceitável na janela. É gasto por incidentes e por deploys arriscados. |

## 2. SLIs e SLOs do donation-service

| # | SLI | Fórmula (PromQL simplificado) | SLO (30d) | Error budget mensal |
|---|---|---|---|---|
| 1 | **Disponibilidade** — fração de requisições HTTP sem resposta 5xx | `1 − (rate(http_requests_total{status=~"5.."}) / rate(http_requests_total))` | **99,9 %** | 0,1 % ≈ **43 min** de erro total ou ~4.300 req com erro em 4,3 M |
| 2 | **Latência** — fração de requisições respondidas em menos de **250 ms** | `rate(http_request_duration_seconds_bucket{le="0.25"}) / rate(http_request_duration_seconds_count)` | **99,0 %** | 1 % das requisições podem exceder 250 ms |

Golden Metrics cobertas: **latência** (SLI 2), **tráfego** (`rate(http_requests_total)`), **erros** (SLI 1),
**saturação** (CPU/memória vs requests, painel no dashboard; HPA a 70 % de CPU).

Visão complementar de borda: `nginx_ingress_controller_requests{ingress="solidarytech"}` mede o que o cliente
realmente viu (inclui falhas antes do pod). Usada como segunda opinião no dashboard.

Recording rules e alertas: `gitops/platform/slo-rules.yaml`. Dashboard: `gitops/platform/dashboards/sre-donation-slo.json`
(Grafana → "SRE — donation-service SLOs & Error Budget").

## 3. SLA com as ONGs parceiras

| Compromisso | Valor | Observação |
|---|---|---|
| Disponibilidade mensal da API de doações | **99,5 %** | Margem de 0,4 pp em relação ao SLO. |
| Latência | 95 % das doações confirmadas em < 1 s | Medida na borda (ingress). |
| Crédito | 10 % da mensalidade de plataforma por ponto percentual abaixo do SLA | Simbólico: a plataforma é sem fins lucrativos. |
| Janela de manutenção | Domingos 04h–05h BRT | Coincide com a `maintenance_window` do RDS no Terraform. |
| Exclusões | Falha da AWS em mais de uma AZ; ataques DDoS; uso indevido da API | |

## 4. Política de error budget

| Budget restante (30d) | Ação |
|---|---|
| > 50 % | Operação normal. Deploys livres (com CI verde). |
| 20 – 50 % | Deploys só com feature flag / canário; revisar alertas `ticket` abertos. |
| < 20 % | **Congelamento de features.** Só correções de confiabilidade. Post-mortem obrigatório para todo incidente. |
| < 0 % (esgotado) | Alerta `DonationErrorBudgetExhausted`. Reunião com a diretoria da ONG; revisão do SLO ou investimento em resiliência. |

## 5. Alertas (multi-window, multi-burn-rate)

Estratégia do *Google SRE Workbook*: alertar pela **velocidade** com que o budget é consumido, em duas janelas
(longa detecta, curta confirma que ainda está acontecendo). Evita tanto alerta tardio quanto alerta que dispara e some.

| Alerta | Condição | Consome | Severidade | Destino |
|---|---|---|---|---|
| `DonationAvailabilityBurnRateCritical` | erro > 14,4 × 0,1 % em 1h **e** 5m | 2 % do budget em 1 h | `page` | on-call (New Relic / PagerDuty) |
| `DonationAvailabilityBurnRateHigh` | erro > 6 × 0,1 % em 6h **e** 30m | 5 % do budget em 6 h | `page` | on-call |
| `DonationLatencyBurnRate` | lentas > 6 × 1 % em 1h | | `ticket` | fila do time |
| `DonationErrorBudgetExhausted` | budget < 0 | | `ticket` | gestão |
| `DonationServiceDown` | nenhum pod respondendo 2 min | | `page` | on-call |

## 6. Como a stack reduz o MTTR

MTTR = detectar + diagnosticar + corrigir + verificar. Cada peça ataca uma parcela:

| Fase | Sem a stack | Com a stack | Ganho |
|---|---|---|---|
| **Detectar** | Doador reclama por e-mail (horas) | Burn-rate alert em ~2-3 min (`for: 2m` depois de a janela de 5m passar do limiar); New Relic Applied Intelligence detecta anomalia de latência/throughput antes do limiar (AIOps) | horas → minutos |
| **Diagnosticar** | SSH no servidor, `grep` em logs | Trace distribuído no New Relic mostra *qual span* falhou (RDS? SQS?); Loki correlaciona logs do pod pelo mesmo intervalo; dashboard mostra saturação | dezenas de min → poucos min |
| **Corrigir** | Alguém edita configuração à mão | `git revert` + ArgoCD faz rollout em ~1 min; selfHeal desfaz mudanças manuais; HPA/liveness/PDB corrigem sozinhos falhas de pod | manual → automático |
| **Verificar** | "Parece que voltou" | SLI 5m volta acima do SLO no dashboard; alerta resolve sozinho | subjetivo → objetivo |

Evidência prática: `scripts/06-sre-chaos.sh errors` injeta uma falha de banco (renomeia a tabela `donations`, como
uma migração quebrada), gera tráfego até o alerta `DonationAvailabilityBurnRateCritical` ficar `firing` e mede a
detecção (MTTD). Em seguida mitiga pelo runbook e imprime `MTTR = detecção + correção` quando o `POST /donations`
volta a `201`. O alerta resolve sozinho quando a janela de 5 min deixa de conter os erros. Anotar os dois valores na
seção SRE do relatório.

Automações que atuam sem humano (auto healing): liveness/readiness probes, `RollingUpdate maxUnavailable=0`,
HPA, PodDisruptionBudget, `topologySpreadConstraints` entre AZs, ArgoCD `selfHeal`+`prune`, DLQ no SQS.
