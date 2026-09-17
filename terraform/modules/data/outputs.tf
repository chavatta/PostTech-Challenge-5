output "rds_endpoint" { value = aws_db_instance.postgres.address }
output "db_url_ssm_parameters" { value = { for k, p in aws_ssm_parameter.db_url : k => p.name } }
output "sqs_queue_url" { value = aws_sqs_queue.donations.url }
output "sqs_dlq_url" { value = aws_sqs_queue.donations_dlq.url }
output "dynamodb_table" { value = aws_dynamodb_table.volunteers.name }
