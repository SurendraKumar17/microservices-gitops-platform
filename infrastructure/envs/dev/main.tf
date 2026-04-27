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
  region       = var.region        # ← FIXED: was var.regionx
}

# ─────────────────────────────────────────
# RDS — Postgres + Secrets Manager
# ─────────────────────────────────────────
module "rds" {
  source     = "../../modules/rds"
  depends_on = [module.vpc]

  env        = "dev"
  project    = "microservices"
  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = module.vpc.vpc_cidr
  subnet_ids = module.vpc.private_subnets
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
  node_role_name    = module.eks.node_role_name
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
# BOOTSTRAP — AWS pre-flight
# Runs after EKS + IAM, before Helm
# ─────────────────────────────────────────
data "aws_caller_identity" "current" {}

resource "null_resource" "bootstrap" {
  triggers = {
    cluster_name = module.eks.cluster_name
  }

  provisioner "local-exec" {
    command     = "bash $(pwd | sed 's|/infrastructure/envs/dev||')/scripts/bootstrap.sh"
    interpreter = ["bash", "-c"]

    environment = {
      CLUSTER_NAME = module.eks.cluster_name
      REGION       = var.region
      VPC_ID       = module.vpc.vpc_id
      ACCOUNT_ID   = data.aws_caller_identity.current.account_id
    }
  }

  depends_on = [module.eks, module.iam]
}

# ─────────────────────────────────────────
# HELM — cluster addons + ArgoCD
# Waits for bootstrap to complete
# ─────────────────────────────────────────
module "helm" {
  source     = "../../modules/helm"
  depends_on = [null_resource.bootstrap]

  cluster_name                = module.eks.cluster_name
  region                      = var.region
  vpc_id                      = module.vpc.vpc_id
  alb_controller_role_arn     = module.iam.alb_controller_role_arn
  ebs_csi_role_arn            = module.iam.ebs_csi_role_arn
  cluster_autoscaler_role_arn = module.iam.cluster_autoscaler_role_arn
  external_secrets_role_arn   = module.iam.external_secrets_role_arn

  alb_controller_replica_count = 1
  argocd_server_replicas       = 1
  argocd_repo_server_replicas  = 1
}

# ─────────────────────────────────────────
# CLEANUP — delete ingresses before destroy
# Prevents VPC deletion failure due to ALB
# ─────────────────────────────────────────
resource "null_resource" "cleanup_alb" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = var.region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws eks update-kubeconfig --region ${self.triggers.region} --name ${self.triggers.cluster_name}
      kubectl delete ingress argocd-ingress -n argocd --ignore-not-found
      kubectl delete ingress -n booking-dev --ignore-not-found --all
      kubectl delete ingress -n booking-prod --ignore-not-found --all
      echo "Waiting for ALBs to be deleted..."
      sleep 60
    EOT
    interpreter = ["bash", "-c"]
  }

  depends_on = [module.helm]
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