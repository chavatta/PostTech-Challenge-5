#!/bin/bash
# Executado pelo LocalStack quando fica "ready" (/etc/localstack/init/ready.d).
# Cria os recursos AWS que os serviços esperam: fila SQS e tabela DynamoDB.
# Em produção esses recursos são criados pelo Terraform (Etapa 2).
set -e
awslocal sqs create-queue --queue-name solidary-donations
awslocal dynamodb create-table \
  --table-name SolidaryTechVolunteers \
  --attribute-definitions AttributeName=volunteer_id,AttributeType=S \
  --key-schema AttributeName=volunteer_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
echo ">>> SQS solidary-donations e DynamoDB SolidaryTechVolunteers criados"
