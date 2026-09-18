# AIOps — New Relic Applied Intelligence

O enunciado pede que as funcionalidades de IA do APM sejam **ativadas e demonstradas**. Passos na UI do New Relic
(não há Terraform aqui porque exige API key de usuário; os passos são curtos e ficam no vídeo).

## 1. Pré-requisitos (feitos pelos scripts)
- Agentes APM nos 3 serviços (`NEW_RELIC_APP_NAME=solidarytech-<serviço>`, distributed tracing ligado) — Etapa 5.
- Integração Kubernetes (`nri-bundle`) enviando infraestrutura, eventos e logs — Etapa 5.

## 2. Detecção de anomalias (Applied Intelligence → Anomaly detection)
1. Alerts & AI → **Anomaly detection** → *Add a configuration*.
2. Nome: `solidarytech-golden-signals`. Escopo: apps `solidarytech-*`.
3. Sinais: **Throughput, Error rate, Response time** (Golden Metrics). Sensibilidade padrão.
4. Notificar em: canal do Discord/e-mail do time (workflow abaixo).
   *Falar:* "Não colocamos limiar fixo. O modelo aprende a linha de base do domingo à noite versus o pico de segunda
   e avisa quando o comportamento foge do esperado, antes de romper o SLO."

## 3. Condições de alerta baseadas em SLO (espelho dos alertas do Prometheus)
Alerts → **Alert conditions (Policies)** → policy `SolidaryTech SRE`:
- **Error budget burn (crítico):** NRQL
  `SELECT percentage(count(*), WHERE error IS true) FROM Transaction WHERE appName = 'solidarytech-donation-service'`
  Critical: `> 1.44` (14,4 × 0,1 %) por 5 min. Warning: `> 0.6` por 30 min.
- **Latência:** `SELECT percentile(duration, 99) FROM Transaction WHERE appName = 'solidarytech-donation-service'`
  Critical `> 0.5` s por 5 min.
- Ligar **Signal loss**: se o serviço parar de enviar dados por 5 min → abrir incidente.

## 4. Correlação e redução de ruído (Incident Intelligence)
1. Alerts & AI → **Decisions**: manter as decisões padrão ativas (correlacionam alertas do mesmo serviço/host em um
   único *Issue*).
2. **Workflows** → criar `sre-oncall`: filtro `priority = critical` → destino (Discord webhook / e-mail).
   Ativar *Enrichment* com a NRQL do runbook (ex.: últimos erros do serviço) para o alerta já chegar com contexto.

## 5. Service Level Management (SLM) no New Relic
APM → `solidarytech-donation-service` → **Service levels** → *Add service level*:
- Availability: 99,9 % em 28 dias (espelha o SLO).
- Latency: 99 % das transações < 250 ms.
O New Relic passa a mostrar error budget e burn rate nativamente. Serve de segunda fonte para o dashboard do Grafana.

## 6. O que demonstrar no vídeo
1. Anomaly detection configurada e um *Issue* aberto durante `scripts/06-sre-chaos.sh errors`.
2. O *Issue* mostrando a correlação (vários sinais → 1 incidente) e o trace com o span de banco falhando.
3. Service levels com o consumo de error budget após o teste.
4. Voltar ao Grafana e mostrar o mesmo evento no alerta de burn rate → duas ferramentas, uma verdade.

## 7. Distributed tracing
APM → Distributed tracing → filtrar `service.name = solidarytech-donation-service`: um trace de `POST /donations`
mostra `nginx (ingress)` → `donation-service` → `Postgres INSERT` → `SQS SendMessage`. O span do SQS aparece
mesmo sendo assíncrono graças ao `txn.NewGoroutine()` no código.
