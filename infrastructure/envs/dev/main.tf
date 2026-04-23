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
# IAM
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
# EKS Access Entry for GitHub Actions
# Why: Modern replacement for aws-auth configmap
# Gives GitHub Actions role access to EKS cluster
# ─────────────────────────────────────────
resource "aws_eks_access_entry" "github_actions" {
  cluster_name  = module.eks.cluster_name
  principal_arn = "arn:aws:iam::635457411372:role/github-actions-ecr-role"
  type          = "STANDARD"
  depends_on    = [module.eks]
}

resource "aws_eks_access_policy_association" "github_actions" {
  cluster_name  = module.eks.cluster_name
  principal_arn = "arn:aws:iam::635457411372:role/github-actions-ecr-role"
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  depends_on    = [module.eks]

  access_scope {
    type = "cluster"
  }
}

# ─────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────
output "cluster_name"            { value = module.eks.cluster_name }
output "cluster_endpoint"        { value = module.eks.cluster_endpoint }
output "region"                  { value = var.region }
output "alb_controller_role_arn" { value = module.iam.alb_controller_role_arn }
output "argocd_role_arn"         { value = module.iam.argocd_role_arn }
output "vpc_id"                  { value = module.vpc.vpc_id }