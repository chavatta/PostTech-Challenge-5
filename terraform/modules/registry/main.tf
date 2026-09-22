# ------------------------------------------------------------------------------
# ECR (imagens dos 3 serviços) e S3 (backups do Velero — requisito DR opção A).
# ------------------------------------------------------------------------------
resource "aws_ecr_repository" "svc" {
  for_each             = toset(var.services)
  name                 = "${var.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE" # DevSecOps: uma tag nunca é sobrescrita (rastreabilidade)
  force_delete         = true        # lab: permite destroy com imagens dentro

  image_scanning_configuration {
    scan_on_push = true # segunda camada de scan além do Trivy no pipeline
  }
  tags = { Service = each.key }
}

# FinOps: mantém só as 10 últimas imagens por repositório. Storage ECR custa US$ 0,10/GB-mês.
resource "aws_ecr_lifecycle_policy" "keep_last" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Manter apenas as 10 imagens mais recentes"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# ---------- Bucket de backup (Velero) ----------
# Algumas contas do AWS Academy têm uma SCP que nega s3:GetBucketObjectLockConfiguration. O provider AWS
# chama essa API ao ler QUALQUER aws_s3_bucket e falha (AccessDenied). Nessas contas: manage_velero_bucket=false;
# o nome continua saindo no output e scripts/08-dr-setup.sh cria o bucket via CLI com as mesmas propriedades.
locals { backup_bucket_name = "${var.name}-velero-${var.account_id}" } # nome global único

resource "aws_s3_bucket" "backup" {
  count         = var.manage_velero_bucket ? 1 : 0
  bucket        = local.backup_bucket_name
  force_destroy = true # lab
}

resource "aws_s3_bucket_versioning" "backup" {
  count  = var.manage_velero_bucket ? 1 : 0
  bucket = aws_s3_bucket.backup[0].id
  versioning_configuration { status = "Enabled" } # protege contra deleção acidental de backup
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  count  = var.manage_velero_bucket ? 1 : 0
  bucket = aws_s3_bucket.backup[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  count                   = var.manage_velero_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.backup[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# FinOps: backups com mais de 30 dias expiram (alinhado à retenção definida no PCN).
resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  count  = var.manage_velero_bucket ? 1 : 0
  bucket = aws_s3_bucket.backup[0].id
  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}
