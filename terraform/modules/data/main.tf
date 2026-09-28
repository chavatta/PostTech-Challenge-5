# ------------------------------------------------------------------------------
# Camada de dados: RDS PostgreSQL (ngo_db + donation_db), DynamoDB (voluntários),
# SQS (eventos de doação) com Dead Letter Queue.
# ------------------------------------------------------------------------------

# ---------- PostgreSQL ----------
resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "db" {
  name        = "${var.name}-rds"
  description = "Postgres: acesso apenas a partir dos nos do EKS"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.allowed_security_group_id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "random_password" "db" {
  length  = 24
  special = false # evita caracteres que quebram a URL de conexão
}

resource "aws_db_instance" "postgres" {
  identifier        = "${var.name}-postgres"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "donation_db" # o hot path; ngo_db é criado por um Job no cluster (scripts/04)
  username = "solidary"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  # DR/RPO: backups automáticos diários + PITR. RPO efetivo do banco de doações ≈ 5 min (PITR).
  backup_retention_period = var.db_backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "Sun:04:00-Sun:05:00"
  copy_tags_to_snapshot   = true

  # Lab: permite destroy limpo. Em produção real: deletion_protection = true e final snapshot.
  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true

  performance_insights_enabled = false # FinOps: não disponível no t3.micro e custaria extra
}

# As URLs ficam no SSM como SecureString: nunca em texto plano no repositório nem em manifests.
resource "aws_ssm_parameter" "db_url" {
  for_each = toset(["ngo_db", "donation_db"])
  name     = "/${var.name}/${each.key}/database_url"
  type     = "SecureString"
  value    = "postgres://solidary:${random_password.db.result}@${aws_db_instance.postgres.address}:5432/${each.key}"
  # O reset do Learner Lab não apaga o SSM Parameter Store: a URL da execução anterior sobra e o create falha com
  # ParameterAlreadyExists. O valor é derivado (RDS + senha DESTE apply), então sobrescrever é o comportamento certo.
  overwrite = true
}

# ---------- DynamoDB ----------
resource "aws_dynamodb_table" "volunteers" {
  name         = "SolidaryTechVolunteers" # nome fixo esperado pelo volunteer-service
  billing_mode = "PAY_PER_REQUEST"        # FinOps: paga por requisição; zero custo ocioso
  hash_key     = "volunteer_id"

  attribute {
    name = "volunteer_id"
    type = "S"
  }

  point_in_time_recovery { enabled = true } # DR: PITR de 35 dias
  server_side_encryption { enabled = true }
}

# ---------- SQS ----------
resource "aws_sqs_queue" "donations_dlq" {
  name                      = "${var.name}-donations-dlq"
  message_retention_seconds = 1209600 # 14 dias: tempo para investigar eventos que falharam
}

resource "aws_sqs_queue" "donations" {
  name                       = "${var.name}-donations"
  visibility_timeout_seconds = 30
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.donations_dlq.arn
    maxReceiveCount     = 5
  })
}
