output "repository_urls" { value = { for k, r in aws_ecr_repository.svc : k => r.repository_url } }
output "backup_bucket" { value = aws_s3_bucket.backup.bucket }
