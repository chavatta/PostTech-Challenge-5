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

_(a preencher)_
