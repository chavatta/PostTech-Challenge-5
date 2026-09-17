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

### 2.5 Destruir ao final da sessão

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

## Etapa 3 — CI/CD DevSecOps

_(a preencher)_
