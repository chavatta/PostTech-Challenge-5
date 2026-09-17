# ------------------------------------------------------------------------------
# EKS no AWS Academy: control plane e nós usam a LabRole (não é possível criar roles).
# Nós em subnets privadas (saem pelo NAT); API do cluster pública para o kubectl/ArgoCD do lab.
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = 7 # FinOps: logs de control plane são baratos, mas retenção infinita não
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.version_k8s
  role_arn = var.role_arn

  vpc_config {
    subnet_ids              = concat(var.public_subnet_ids, var.private_subnet_ids)
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true # quem roda o apply vira admin do cluster
  }

  # Audit log = evidência de segurança; api/authenticator ajudam no MTTR de problemas de acesso
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_cloudwatch_log_group.cluster]
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-ng"
  node_role_arn   = var.role_arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.instance_types
  capacity_type   = var.capacity_type
  disk_size       = 20

  scaling_config {
    desired_size = var.desired
    min_size     = var.min
    max_size     = var.max
  }

  update_config {
    max_unavailable = 1
  }

  labels = { role = "general" }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size] # deixa o autoscaler mandar
  }
}

# ------------------------------------------------------------------------------
# Add-ons gerenciados. O EBS CSI driver é necessário para PersistentVolumes
# (Prometheus, Loki, Velero volume snapshots). Sem OIDC/IRSA no Academy, o driver
# usa as permissões da LabRole dos nós.
# ------------------------------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.default] # coredns precisa de nós para agendar
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.default]
}
