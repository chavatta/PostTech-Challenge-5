# FinOps — Tagging, Rightsizing e Forecast

## 1. Estratégia de tagging (implementada no Terraform)

Toda tag obrigatória é aplicada via `default_tags` do provider AWS (`terraform/providers.tf`).
Nada que o Terraform cria nasce sem tag: o provider injeta em **todos** os recursos dele que suportam tags.

| Tag | Valor | Uso |
|---|---|---|
| `Project` | `SolidaryTech` | filtro principal no Cost Explorer / Budget |
| `Environment` | `Production` | separar prod de futuros ambientes |
| `CostCenter` | `NGO-Core` | rateio contábil da ONG |
| `ManagedBy` | `Terraform` | identifica recurso órfão (sem a tag = criado à mão = violação) |
| `Owner` | time | responsável |
| `Site` | `primary` / `dr` | custo do ambiente espelho separado do primário |
| `Service` | nome do serviço | só nos repositórios ECR |

Recursos criados pelo Kubernetes (NLB do ingress) recebem tags pela annotation
`service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags` (`gitops/platform/values/ingress-nginx.yaml`).
Os demais que o EKS/K8s cria em runtime não passam pelo provider: instâncias e launch template do node group, ENIs
do VPC CNI, volumes EBS de PVC, snapshots do Velero e o SG `eks-cluster-sg-*` nascem só com as tags do próprio
EKS/K8s (`eks:cluster-name`, `kubernetes.io/cluster/<nome>`, `ebs.csi.aws.com/*`, `velero.io/*`...).
Próximo passo: propagar as tags para eles (`tag_specifications` no launch template, `extraVolumeTags` no EBS CSI).

Evidências: `scripts/07-finops-report.sh tags` (inventário por `CostCenter`; auditoria dos recursos do Terraform sem
`Project`, que deve dar zero; e a lista à parte do que o EKS/K8s criou em runtime, com o dono tirado das tags:
cluster, nodegroup, PVC, backup, service) e a seção
"Tags" de qualquer recurso no console. Cost allocation tags precisam ser ativadas uma vez em
Billing → Cost allocation tags (`Project`, `CostCenter`, `Site`) para aparecerem no Cost Explorer.

## 2. Rightsizing

### Método
1. Subir com valores conservadores.
2. Gerar carga real (`scripts/05-observability.sh` gera 2 min de tráfego; `06-sre-chaos.sh load` faz pico).
3. Ler `kubectl top pods --containers` e o painel "Saturação" do dashboard SRE (`scripts/04-gitops-demo.sh rightsizing`).
4. Ajustar `requests` para ~p95 do uso observado e `limits` com folga de 2–3× para picos; commitar no overlay (GitOps).
5. HPA cuida da escala horizontal; o pod não precisa ser grande, precisa ser replicável.

### Valores atuais (`gitops/base/*/deployment.yaml`)

| Serviço | Runtime | CPU req / lim | Mem req / lim | Réplicas (HPA) | Justificativa |
|---|---|---|---|---|---|
| donation-service | Go, binário estático | 50m / 300m | 32Mi / 96Mi | 2 – 6 | Go ocioso usa ~10 MiB; hot path recebe mais réplicas e teto de CPU maior para picos de doação |
| ngo-service | Python/gunicorn 1×8 | 50m / 250m | 96Mi / 192Mi | 1 – 3 | CRUD leve; Flask + psycopg ≈ 60–80 MiB |
| volunteer-service | Python/gunicorn 1×8 | 50m / 250m | 96Mi / 192Mi | 1 – 3 | igual ao ngo; boto3 adiciona ~15 MiB |

Preencher a coluna "uso medido" no relatório com a saída de `kubectl top` após a carga (evidência obrigatória).

Também dimensionados: Prometheus (512Mi req, retenção 7d), Loki (256Mi, 7d), Grafana, ingress (2 réplicas),
todos com requests/limits nos values dos charts. Sem requests, o scheduler não consegue empacotar bem os nós.

## 3. Forecast mensal (us-east-1, on-demand, preços de lista)

Ambiente **primário ligado 24×7**:

| Recurso | Dimensionamento | Preço unitário | Mensal (730 h) |
|---|---|---|---|
| EKS control plane | 1 cluster | US$ 0,10/h | **73,00** |
| EC2 nós | 2 × t3.medium | US$ 0,0416/h | **60,74** |
| EBS nós + PVs | 2×20 GB + 20 GB gp2/gp3 | ~US$ 0,08–0,10/GB | **~5,60** |
| NAT Gateway | 1 × | US$ 0,045/h + US$ 0,045/GB | **32,85** + tráfego (~2,00) |
| NLB (ingress) | 1 × | US$ 0,0225/h + LCU | **16,43** + ~2,00 |
| RDS PostgreSQL | db.t3.micro, 20 GB gp3, backup 7d | US$ 0,017/h + storage | **12,41** + 2,30 |
| DynamoDB | on-demand, PITR, baixo volume | por requisição | **< 1,00** |
| SQS | < 1 M req/mês (free tier) | — | **0,00** |
| ECR | < 3 GB | US$ 0,10/GB | **0,30** |
| S3 (Velero) | ~5 GB, lifecycle 30d | US$ 0,023/GB | **0,12** |
| CloudWatch Logs (EKS audit) | ~2 GB, retenção 7d | US$ 0,50/GB | **1,00** |
| New Relic | free tier (100 GB/mês, 1 usuário full) | — | **0,00** |
| **Total primário** | | | **≈ US$ 210 / mês** |

Site de **DR warm standby** (`environments/dr.tfvars`, 1 nó, sem NLB até ativar): ≈ US$ 145/mês se ficar ligado;
**≈ US$ 0** se a estratégia for "sobe em 20 min com `terraform apply`" (opção adotada: infra como código *é* o standby).

Custo de **lab** (ambiente ligado só durante sessões de ~4 h, ~10 sessões): ≈ US$ 12–15 no total.

## 4. Recomendações de otimização (nativas de nuvem)

| # | Recomendação | Economia estimada | Como |
|---|---|---|---|
| 1 | **Spot Instances no node group** | até 70 % dos US$ 60 de EC2 (≈ US$ 40/mês) | `node_capacity_type = "SPOT"` no Terraform; apps já são stateless com PDB e várias réplicas |
| 2 | **Graviton (t4g.medium)** | ~20 % de EC2 e RDS (db.t4g.micro) | trocar `instance_types`; imagens já são multi-arch-friendly (Go estático, Python slim tem arm64) |
| 3 | **Savings Plan Compute 1 ano** | ~30 % sobre EC2 restante | compromisso de uso, sem mudar código |
| 4 | **Desligar fora do horário** (ambiente não-prod) | 65 % | `terraform destroy` agendado / node group min=0 à noite |
| 5 | NAT Gateway → **VPC endpoints** (S3, ECR, SQS, DynamoDB) | tráfego NAT ~US$ 0,045/GB → 0 para esses serviços | `aws_vpc_endpoint` no módulo network |
| 6 | Retenção curta de métricas/logs (já aplicado: 7 dias) | evita crescimento de EBS | values dos charts |
| 7 | **AWS Budget** com alerta em 80 % do forecast | evita surpresa | `enable_budget = true` (fora do Academy) |

Recomendação principal para o relatório: **Spot no node group** (maior impacto, zero mudança de código, adequado
porque os serviços são stateless, têm HPA, PDB e RollingUpdate).
