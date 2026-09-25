variable "region" {
  description = "Região AWS. us-east-1 no primário; outra região para o warm standby (DR)."
  type        = string
  default     = "us-east-1"
}

variable "site" {
  description = "Identifica o site: primary ou dr. Entra no nome dos recursos e nas tags."
  type        = string
  default     = "primary"
  validation {
    condition     = contains(["primary", "dr"], var.site)
    error_message = "site deve ser primary ou dr."
  }
}

variable "environment" {
  description = "Tag Environment obrigatória (enunciado pede Production)."
  type        = string
  default     = "Production"
}

variable "owner" {
  description = "Tag Owner: time responsável."
  type        = string
  default     = "PosTech-Grupo"
}

variable "project" {
  description = "Prefixo dos nomes de recursos."
  type        = string
  default     = "solidarytech"
}

variable "lab_role_name" {
  description = "Role pré-existente do AWS Academy. Não é possível criar IAM roles no Learner Lab."
  type        = string
  default     = "LabRole"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  description = "Quantidade de AZs (2 é o mínimo do EKS)."
  type        = number
  default     = 2
}

variable "eks_version" {
  type    = string
  default = "1.31"
}

variable "node_instance_types" {
  description = "Rightsizing: t3.medium (2 vCPU / 4 GiB) é o menor tipo que comporta a stack de observabilidade."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND ou SPOT. SPOT é a recomendação FinOps (até 90% mais barato) para workloads tolerantes."
  type        = string
  default     = "ON_DEMAND"
}

variable "node_desired" {
  type    = number
  default = 2
}
variable "node_min" {
  type    = number
  default = 2
}
variable "node_max" {
  type    = number
  default = 4
}

variable "db_instance_class" {
  description = "Rightsizing: db.t3.micro atende o volume de uma ONG; escalar é 1 linha."
  type        = string
  default     = "db.t3.micro"
}

variable "db_multi_az" {
  description = "Multi-AZ dobra o custo do RDS; false no lab, true seria a recomendação para o hot path real."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Retenção de backups automáticos do RDS. Define o RPO máximo do banco de doações."
  type        = number
  default     = 7
}

variable "enable_budget" {
  description = "Cria AWS Budget com alerta. No Learner Lab a API de Budgets pode ser negada; desligue se o apply falhar."
  type        = bool
  default     = false
}

variable "budget_limit_usd" {
  type    = number
  default = 100
}

variable "budget_email" {
  type    = string
  default = ""
}

variable "manage_velero_bucket" {
  type        = bool
  default     = true
  description = "Definido automaticamente por scripts/02-terraform-apply.sh: false quando a SCP da conta nega s3:GetBucketObjectLockConfiguration; aí o bucket é criado via AWS CLI com as mesmas propriedades."
}
