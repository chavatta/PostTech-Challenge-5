provider "aws" {
  region = var.region

  # ---------------------------------------------------------------------------
  # FinOps — Estratégia de tagging (requisito 2 do enunciado).
  # default_tags aplica as tags obrigatórias em TODO recurso criado por este provider,
  # sem depender de cada módulo lembrar. Impossível criar recurso sem tag.
  # ---------------------------------------------------------------------------
  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = var.environment
      CostCenter  = "NGO-Core"
      ManagedBy   = "Terraform"
      Owner       = var.owner
      Site        = var.site # primary | dr — separa custo do ambiente espelho
    }
  }
}
