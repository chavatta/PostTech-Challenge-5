variable "name" { type = string }
variable "services" { type = list(string) }
variable "account_id" { type = string }
variable "region" { type = string }
variable "manage_velero_bucket" {
  type        = bool
  default     = true
  description = "false quando a SCP da conta nega s3:GetBucketObjectLockConfiguration (o provider AWS falha ao ler qualquer bucket). O bucket passa a ser criado, com as mesmas propriedades, por scripts/08-dr-setup.sh."
}
