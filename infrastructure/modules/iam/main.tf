locals {
  oidc_id = replace(var.oidc_provider_url, "https://", "")
  tags = {
    Environment = var.env
    Project     = var.project
    ManagedBy   = "terraform"
  }
}

# ────────────────────────────────────────────────
# IRSA — AWS Load Balancer Controller
# Scope: only the specific service account in kube-system
# ────────────────────────────────────────────────
resource "aws_iam_role" "alb_controller" {
  name = "${var.cluster_name}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_id}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${local.oidc_id}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
  tags = local.tags
}

resource "aws_iam_policy" "alb_controller" {
  name   = "${var.cluster_name}-alb-controller-policy"
  policy = var.alb_policy_json
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ────────────────────────────────────────────────
# IRSA — ArgoCD
# Scope: argocd-server service account in argocd ns
# ────────────────────────────────────────────────
resource "aws_iam_role" "argocd" {
  name = "${var.cluster_name}-argocd"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_id}:sub" = "system:serviceaccount:argocd:argocd-server"
          "${local.oidc_id}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "argocd_ecr" {
  role       = aws_iam_role.argocd.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ── IRSA — EBS CSI Driver ──
resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_id}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_id}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role" "alb_controller" {
  name = "${var.cluster_name}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
  tags = local.tags
}