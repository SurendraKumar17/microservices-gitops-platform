provider "aws" {
  region = var.region
}

# ── Kubernetes & Helm providers ───────────────────────────────
# Required for helm_release and kubernetes_ingress_v1 resources
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
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
# HELM — cluster addons + ArgoCD
# Must come after EKS and IAM are ready
# ─────────────────────────────────────────
module "helm" {
  source     = "../../modules/helm"
  depends_on = [module.eks, module.iam]

  cluster_name                = module.eks.cluster_name
  region                      = var.region
  vpc_id                      = module.vpc.vpc_id
  alb_controller_role_arn     = module.iam.alb_controller_role_arn
  ebs_csi_role_arn            = module.iam.ebs_csi_role_arn
  cluster_autoscaler_role_arn = module.iam.cluster_autoscaler_role_arn

  # dev — single replicas to save cost
  alb_controller_replica_count = 1
  argocd_server_replicas       = 1
  argocd_repo_server_replicas  = 1
}

# ─────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────
output "cluster_name"            { value = module.eks.cluster_name }
output "cluster_endpoint"        { value = module.eks.cluster_endpoint }
output "region"                  { value = var.region }
output "vpc_id"                  { value = module.vpc.vpc_id }
output "alb_controller_role_arn" { value = module.iam.alb_controller_role_arn }
output "argocd_role_arn"         { value = module.iam.argocd_role_arn }
output "argocd_url" {
  description = "ArgoCD ALB URL — available ~2 mins after apply"
  value       = "http://${module.helm.argocd_hostname}"
}