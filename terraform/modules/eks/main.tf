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

# Launch template explícito: IMDSv2 obrigatório (hardening) e hop limit 2. Sem IRSA no Academy, TODOS os pods
# (EBS CSI, Velero, donation-service -> SQS, volunteer -> DynamoDB) pegam credenciais da LabRole via IMDS do nó;
# com hop limit 1 a chamada morre na rede do pod e os pods ficam em CrashLoop (add-on preso em CREATING).
resource "aws_launch_template" "nodes" {
  name_prefix = "${var.name}-ng-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-node" }
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-ng"
  node_role_arn   = var.role_arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.instance_types
  capacity_type   = var.capacity_type

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

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
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  # precisa de rede (vpc-cni) e DNS (coredns) prontos para os pods do controller subirem;
  # no lab já vimos o add-on ficar em CREATING por 20 min quando criado cedo demais.
  depends_on = [aws_eks_node_group.default, aws_eks_addon.vpc_cni, aws_eks_addon.coredns]
  timeouts { create = "30m" }
}
