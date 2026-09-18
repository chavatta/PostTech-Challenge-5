# Segurança — decisões e exceções

## Camadas de DevSecOps no pipeline (`.github/workflows/ci.yml`)

| Gate | Ferramenta | O que pega | Bloqueia? |
|---|---|---|---|
| Segredos no git | gitleaks | senhas, tokens, chaves commitadas | sim |
| IaC | terraform fmt/validate + Trivy config | misconfig de Terraform (SG aberto, bucket público, sem criptografia) | sim (CRITICAL/HIGH) |
| SAST | semgrep (rulesets python, golang, dockerfile, secrets) + ruff regras `S` (bandit) | injeção, uso inseguro de APIs, hardcoded secrets | sim |
| SCA | Trivy fs | CVEs em `requirements.txt` e `go.sum` | sim (CRITICAL/HIGH, com fix disponível) |
| Dockerfile | hadolint | más práticas de build | sim (warning+) |
| Imagem | Trivy image | CVEs no SO base + libs da imagem final | sim (CRITICAL/HIGH, com fix) |
| Registry | ECR scan on push | 2ª opinião contínua depois do push | não (alerta) |
| Qualidade | SonarCloud (opcional, `vars.SONAR_ENABLED=true`) | bugs, code smells, cobertura | não |

Regra `ignore-unfixed`: CVE sem correção publicada não bloqueia, senão o pipeline ficaria vermelho
para sempre por um bug do Debian sem patch. Fica visível no relatório do Trivy.

## Exceções de IaC aceitas (`.trivyignore`)

Todas decorrem de duas restrições do AWS Academy Learner Lab, ou de FinOps no lab:

1. **Sem KMS**: o Learner Lab não permite criar chaves KMS. Usamos criptografia gerenciada pelo serviço
   (AES256 no S3, SSE do SQS, criptografia padrão do RDS/DynamoDB/ECR). Em produção: CMK por serviço.
2. **Sem IAM**: não criamos roles/policies; tudo roda com a `LabRole`. Em produção: IRSA por serviço
   com privilégio mínimo (donation-service só `sqs:SendMessage`, volunteer-service só a tabela).
3. **Endpoint público do EKS**: kubectl/ArgoCD são operados de fora da VPC no lab. Em produção: endpoint
   privado + bastion/VPN.
4. **Deletion protection off / skip final snapshot**: para `terraform destroy` limpo ao fim de cada sessão.
5. **VPC Flow Logs / S3 access logs desligados**: custo de CloudWatch. Em produção ligar com retenção curta.

## Exceções de SAST (semgrep, marcadas com `nosemgrep` no código)

| Regra | Onde | Justificativa |
|---|---|---|
| `go.lang.security.audit.net.use-tls.use-tls` | `donation-service/main.go` | TLS termina no Load Balancer/Ingress; o pod só recebe HTTP dentro da VPC privada. |
| `python.flask...avoid_app_run_with_bad_host` | `ngo-service/app.py`, `volunteer-service/app.py` | `app.run` só executa em `python app.py` (dev). O container usa gunicorn como entrypoint. |

## Postura de runtime (Etapa 4)

- Containers non-root, filesystem read-only, `allowPrivilegeEscalation: false`, capabilities dropadas.
- NetworkPolicy: donation-service só recebe tráfego do ingress e só fala com RDS/SQS.
- Secrets de banco vêm do SSM (SecureString) e viram `Secret` do Kubernetes por script; nunca no git.
