# ------------------------------------------------------------------------------
# Composição da infraestrutura. Cada módulo é independente e recebe só o que precisa,
# o que permite reutilizar o mesmo código para a região de DR (environments/dr.tfvars).
# ------------------------------------------------------------------------------

module "network" {
  source       = "./modules/network"
  name         = local.name
  vpc_cidr     = var.vpc_cidr
  az_count     = var.az_count
  cluster_name = local.name
}

module "registry" {
  source     = "./modules/registry"
  name       = local.name
  services   = keys(local.services)
  account_id = data.aws_caller_identity.current.account_id
  region     = var.region
}

module "eks" {
  source             = "./modules/eks"
  name               = local.name
  version_k8s        = var.eks_version
  role_arn           = data.aws_iam_role.lab.arn
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  instance_types     = var.node_instance_types
  capacity_type      = var.node_capacity_type
  desired            = var.node_desired
  min                = var.node_min
  max                = var.node_max
}

module "data" {
  source                    = "./modules/data"
  name                      = local.name
  vpc_id                    = module.network.vpc_id
  private_subnet_ids        = module.network.private_subnet_ids
  allowed_security_group_id = module.eks.cluster_security_group_id
  db_instance_class         = var.db_instance_class
  db_multi_az               = var.db_multi_az
  db_backup_retention_days  = var.db_backup_retention_days
}

# ------------------------------------------------------------------------------
# FinOps — Budget com alerta (opcional no Learner Lab).
# ------------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  count        = var.enable_budget ? 1 : 0
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$SolidaryTech"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}
