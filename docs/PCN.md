# Plano de Continuidade de Negócios (PCN) — SolidaryTech

**Documento executivo.** Público: diretoria da SolidaryTech e ONGs parceiras.
Versão 1.0 — setembro/2026.

## 1. Objetivo

Garantir que **doações continuem sendo recebidas e registradas** mesmo diante da perda do ambiente principal
(região `us-east-1` da AWS), com perda de dados e tempo de indisponibilidade dentro de limites acordados.

## 2. Análise de impacto (BIA)

| Processo | Serviço | Criticidade | Impacto de 1 h parado |
|---|---|---|---|
| Receber doação | `donation-service` + RDS + SQS | **Crítico** | doações perdidas; dano de reputação após exposição em rede nacional |
| Cadastro de ONG | `ngo-service` + RDS | Alto | novas ONGs não entram; existentes não são afetadas |
| Inscrição de voluntário | `volunteer-service` + DynamoDB | Médio | inscrições adiadas |
| Observabilidade / GitOps | Prometheus, Grafana, ArgoCD | Suporte | cegueira operacional; não afeta doador diretamente |

## 3. Objetivos de recuperação

| Ativo | **RPO** (perda máxima de dados) | **RTO** (tempo máximo parado) | Mecanismo |
|---|---|---|---|
| **Banco de doações (RDS)** | **5 minutos** | **60 minutos** | Point-in-Time Recovery (logs contínuos, retenção 7 d) + snapshot diário + cópia cross-region (`scripts/08-dr-drill.sh rds`) |
| Banco de ONGs (RDS, mesma instância) | 5 minutos | 60 minutos | idem |
| Voluntários (DynamoDB) | ~segundos | 30 minutos | PITR nativo (35 d); tabela recriável por Terraform |
| Fila de eventos (SQS) | 0 (mensagens em trânsito são reprocessáveis) | 20 minutos | Terraform recria; DLQ retém falhas 14 d |
| Estado do cluster (manifests, configs, PVs) | **1 hora** | **30 minutos** | Velero: backup horário para S3 + restore (`08-dr-drill.sh restore`) |
| Infraestrutura completa (região inteira) | — | **≈ 45 minutos** | Terraform warm standby: `scripts/02-terraform-apply.sh dr` (≈ 20 min) + bootstrap ArgoCD (`04-bootstrap-cluster.sh`, ≈ 10 min) + restore RDS a partir do snapshot copiado (≈ 15 min) |

**RTO total para desastre regional: até 1 hora. RPO das doações: 5 minutos.**

## 4. Cenários e resposta

| Cenário | Detecção | Resposta | Automático? |
|---|---|---|---|
| Pod/nó falha | liveness, node NotReady | Kubernetes reagenda; HPA/PDB mantêm capacidade | sim |
| Deploy ruim | burn-rate alert | `git revert` → ArgoCD rollout | semi (humano faz o revert) |
| Namespace apagado / config corrompida | ArgoCD OutOfSync, alerta `DonationServiceDown` | ArgoCD selfHeal; se PV perdido, `velero restore` | sim / manual |
| Perda do RDS | alarme RDS, 5xx | Restore PITR para novo endpoint; atualizar SSM + Secret; rollout | manual (runbook em ITSM.md) |
| **Perda da região** | múltiplos alertas + AWS Health | ativar site DR (seção 5) | manual, roteirizado |

## 5. Estratégia de DR adotada (as duas opções do enunciado)

**Opção A — Backup cross-region (Velero):** `Schedule` horário do namespace `solidarytech` (`velero-solidarytech-hourly`,
retenção 72 h) e diário da plataforma (`velero-platform-daily`, 30 dias) para o bucket S3 versionado/criptografado
criado pelo Terraform. Os Schedules são ligados pelo `08-dr-setup.sh`, junto com o bucket real. Restore testado pelo
`08-dr-drill.sh restore`, que pausa o ArgoCD, apaga o namespace, restaura só pelo Velero e mede o RTO real.

**Opção B — Ativo-passivo (Terraform warm standby):** o mesmo código (`terraform/`) sobe um espelho em `us-west-2`
com `terraform workspace select dr && terraform apply -var-file=environments/dr.tfvars`. Estado desejado das
aplicações já está no git; o ArgoCD do site DR aponta para o mesmo repositório. Custo em repouso ≈ zero.

Procedimento de ativação (falha regional):
1. Declarar incidente Sev-1 (ITSM.md) e comunicar ONGs (template em ITSM.md).
2. `scripts/02-terraform-apply.sh dr` (≈ 20 min).
3. Restaurar RDS no DR a partir do snapshot copiado: `aws rds restore-db-instance-from-db-snapshot --region us-west-2 ...`; gravar a nova URL no SSM do site DR.
4. Bootstrap do GitOps no cluster do DR (ArgoCD sincroniza os 3 serviços). O `scripts/04-bootstrap-cluster.sh` fixa o
   site primário de propósito (`use_site primary`); na ativação, rodá-lo com `use_site dr` no lugar.
5. Apontar o DNS público para o novo NLB (TTL 60 s recomendado).
6. Validar com o smoke test do script; encerrar incidente; post-mortem.

## 6. Testes e manutenção

| Teste | Frequência | Evidência |
|---|---|---|
| Restore Velero (namespace) | mensal + antes de cada release grande | `08-dr-drill.sh restore` → RTO medido |
| Snapshot RDS cross-region | semanal (automatizável via EventBridge) | `08-dr-drill.sh rds` |
| Subida do site DR | trimestral | `02-terraform-apply.sh dr` + smoke test |
| Revisão deste PCN | semestral ou após incidente Sev-1 | histórico no git |

## 7. Papéis

| Papel | Responsável | Contato |
|---|---|---|
| Coordenador de crise | Líder de plataforma | on-call |
| Executor técnico | Engenheiro SRE de plantão | on-call |
| Comunicação com ONGs | Diretoria SolidaryTech | e-mail / WhatsApp institucional |
