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
resource "aws_s3_bucket" "backup" {
  bucket        = "${var.name}-velero-${var.account_id}" # nome global único
  force_destroy = true                                   # lab
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration { status = "Enabled" } # protege contra deleção acidental de backup
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# FinOps: backups com mais de 30 dias expiram (alinhado à retenção definida no PCN).
resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}
