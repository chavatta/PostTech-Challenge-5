# AIOps — New Relic Applied Intelligence

O enunciado pede que as funcionalidades de IA do APM sejam **ativadas e demonstradas**. Toda a configuração é código:
`scripts/05-newrelic-aiops.sh` aplica tudo via NerdGraph, de forma idempotente (roda de novo sem duplicar).
Roda uma vez por conta New Relic e não depende do cluster.

```bash
export NEW_RELIC_API_KEY=NRAK-...        # User key (New Relic -> API keys -> Create a key -> User). Não é a license INGEST.
export NEW_RELIC_ACCOUNT_ID=8116534      # conta do projeto
scripts/05-newrelic-aiops.sh
```

## 1. Pré-requisitos (feitos pelos scripts)
- Agentes APM nos 3 serviços (`NEW_RELIC_APP_NAME=solidarytech-<serviço>`, distributed tracing ligado) — Etapa 5.
- Integração Kubernetes (`nri-bundle`) enviando infraestrutura, eventos e logs — Etapa 4/5.
- Para os Service Levels, a entidade APM `solidarytech-donation-service` precisa existir (Etapa 5 rodada ao menos uma vez).

## 2. Detecção de anomalias (condições baseline, sem limiar fixo)
Policy `SolidaryTech SRE` → três condições **Anomaly (baseline)** sobre as Golden Metrics, `FACET appName`
(um modelo por serviço `solidarytech-*`), disparando a 3 desvios-padrão por 5 min:
- `AIOps: anomalia de throughput` (acima **e** abaixo do normal: queda de tráfego também é incidente)
- `AIOps: anomalia de taxa de erro` (acima)
- `AIOps: anomalia de tempo de resposta` (acima)

*Falar:* "Não colocamos limiar fixo. O modelo aprende a linha de base do domingo à noite versus o pico de segunda
e avisa quando o comportamento foge do esperado, antes de romper o SLO."

## 3. Condições de alerta baseadas em SLO (espelho dos alertas do Prometheus)
Mesma policy:
- **`SLO: burn rate de erro do donation-service`**: `SELECT percentage(count(*), WHERE error IS true) FROM Transaction
  WHERE appName = 'solidarytech-donation-service'`. Critical `> 1.44` (14,4 × 0,1 %) por 5 min; Warning `> 0.6` por 30 min.
  **Signal loss** ligado: 5 min sem dados abre incidente (pod morto não gera erro, gera silêncio).
- **`SLO: latência p99 do donation-service > 500 ms`**: `percentile(duration, 99)`, Critical `> 0.5` s por 5 min.

Todas as condições apontam o runbook (`docs/ITSM.md#runbook-donation-5xx`).

> Efeito colateral conhecido: com o ambiente desligado (lab parado), o signal loss abre um incidente e o workflow
> manda e-mail. É o comportamento correto em produção; no lab, dá para desligar a condição em Alerts → Alert conditions.

## 4. Correlação e notificação (Incident Intelligence)
- **Decisions**: ficam as decisões padrão ativas (correlacionam alertas do mesmo serviço/host em um único *Issue*).
- **Workflow `sre-oncall`**: issues **críticos** da policy `SolidaryTech SRE` → e-mail do dono da API key (canal
  `sre-oncall-email`). O script tenta criar com *enrichment* NRQL (erros recentes do donation-service no corpo do
  alerta); no plano gratuito do New Relic esse recurso não existe (`MISSING_ENTITLEMENT`) e o workflow é criado sem ele.

## 5. Service Level Management (SLM) no New Relic
APM → `solidarytech-donation-service` → **Service levels** (criados pelo script, janela de 28 dias):
- `donation-service: disponibilidade`: 99,9 % (eventos ruins = `error IS true`), espelha o SLO do `docs/SRE.md`.
- `donation-service: latência < 250 ms`: 99 % das transações.
O New Relic passa a mostrar error budget e burn rate nativamente. Serve de segunda fonte para o dashboard do Grafana.

## 6. O que demonstrar no vídeo
1. Anomaly detection configurada e um *Issue* aberto durante `scripts/06-sre-chaos.sh errors`.
2. O *Issue* mostrando a correlação (vários sinais → 1 incidente) e o trace com o span de banco falhando.
3. Service levels com o consumo de error budget após o teste.
4. Voltar ao Grafana e mostrar o mesmo evento no alerta de burn rate → duas ferramentas, uma verdade.

## 7. Distributed tracing
APM → Distributed tracing → filtrar `service.name = solidarytech-donation-service`: um trace de `POST /donations`
mostra `nginx (ingress)` → `donation-service` → `Postgres INSERT` → `SQS SendMessage`. O publish no SQS é feito
antes de responder (síncrono, com timeout de 2 s), então o span `SQS SendMessage` fica dentro da transação de
`POST /donations`. Numa goroutine ele não aparecia: a transação termina no retorno do handler e o agente descarta
segmentos abertos depois disso. Para o consumidor da fila, o evento continua assíncrono.
