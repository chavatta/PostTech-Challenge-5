variable "name" { type = string }
variable "services" { type = list(string) }
variable "account_id" { type = string }
variable "region" { type = string }
variable "manage_velero_bucket" {
  type        = bool
  default     = true
  description = "Definido automaticamente por scripts/02-terraform-apply.sh: false quando a SCP da conta nega s3:GetBucketObjectLockConfiguration; aí o bucket é criado via AWS CLI com as mesmas propriedades."
}
