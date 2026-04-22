provider "aws" {
  region = var.region
}

# ─────────────────────────────────────────
# VPC
# ─────────────────────────────────────────
module "vpc" {
  source  = "../../modules/vpc"
  region  = var.region
  cidr    = "10.0.0.0/16"
  azs     = ["us-east-1a", "us-east-1b"]
  env     = "dev"
  project = "microservices"
}

# ─────────────────────────────────────────
# EKS
# ─────────────────────────────────────────
module "eks" {
  source       = "../../modules/eks"
  depends_on   = [module.vpc]
  env          = "dev"
  cluster_name = var.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnets
  region       = var.region
}

# ─────────────────────────────────────────
# IAM (after EKS for OIDC)
# ─────────────────────────────────────────
module "iam" {
  source            = "../../modules/iam"
  depends_on        = [module.eks]
  env               = "dev"
  project           = "microservices"
  cluster_name      = module.eks.cluster_name
  oidc_provider_url = module.eks.oidc_provider_url
  oidc_provider_arn = module.eks.oidc_provider_arn
  alb_policy_json   = file("../../modules/iam/alb-policy.json")
}

# ─────────────────────────────────────────
# KUBERNETES PROVIDER (NEW)
# ─────────────────────────────────────────
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.region
    ]
  }
}

# ─────────────────────────────────────────
# AWS AUTH CONFIGMAP (CRITICAL FIX)
# ─────────────────────────────────────────
resource "kubernetes_config_map_v1" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = <<YAML
- rolearn: ${module.eks.node_group_role_arn}
  username: system:node:{{EC2PrivateDNSName}}
  groups:
    - system:bootstrappers
    - system:nodes

- rolearn: arn:aws:iam::635457411372:role/github-actions-ecr-role
  username: github-actions
  groups:
    - system:masters
YAML
  }

  depends_on = [module.eks]
}

# ─────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "region" {
  value = var.region
}

output "alb_controller_role_arn" {
  value = module.iam.alb_controller_role_arn
}

output "argocd_role_arn" {
  value = module.iam.argocd_role_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}