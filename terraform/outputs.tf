output "region" { value = var.region }
output "account_id" { value = data.aws_caller_identity.current.account_id }
output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
output "ecr_repositories" { value = module.registry.repository_urls }
output "velero_bucket" { value = module.registry.backup_bucket }
output "rds_endpoint" { value = module.data.rds_endpoint }
output "db_url_ssm_parameters" {
  description = "Parâmetros SSM (SecureString) com as DATABASE_URLs. Lidos pelo script que cria os Secrets no cluster."
  value       = module.data.db_url_ssm_parameters
}
output "sqs_queue_url" { value = module.data.sqs_queue_url }
output "dynamodb_table" { value = module.data.dynamodb_table }
