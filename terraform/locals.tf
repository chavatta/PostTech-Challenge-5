locals {
  name = "${var.project}-${var.site}" # ex: solidarytech-primary / solidarytech-dr
  services = {
    ngo-service       = { port = 8081 }
    donation-service  = { port = 8082 }
    volunteer-service = { port = 8083 }
  }
}

data "aws_caller_identity" "current" {}

# LabRole: única role disponível no AWS Academy. Usada pelo control plane do EKS e pelos nós.
data "aws_iam_role" "lab" {
  name = var.lab_role_name
}
