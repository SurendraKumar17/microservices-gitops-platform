module "vpc" {
  source          = "../../modules/vpc"
  env             = "dev"
  vpc_cidr        = var.vpc_cidr
  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets
}

module "iam" {
  source            = "../../modules/iam"
  depends_on        = [module.eks]
  env               = "dev"
  project           = "microservices"
  cluster_name      = module.eks.cluster_name
  oidc_provider_url = module.eks.oidc_provider_url   # ← was oidc_url
  oidc_provider_arn = module.eks.oidc_provider_arn
  alb_policy_json   = file("../../modules/iam/alb-policy.json")
}

module "eks" {
  source       = "../../modules/eks"
  depends_on   = [module.vpc]
  env          = "dev"
  cluster_name = var.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnets          # ← was private_subnet_ids
  region       = var.region
}

module "helm" {
  source       = "../../modules/helm"
  depends_on   = [module.eks, module.iam]
  cluster_name             = module.eks.cluster_name
  cluster_endpoint         = module.eks.cluster_endpoint
  cluster_ca               = module.eks.cluster_ca
  region                   = var.region
  alb_controller_role_arn  = module.iam.alb_controller_role_arn
  ebs_csi_role_arn         = module.iam.ebs_csi_role_arn
}

output "cluster_name"   { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "region"         { value = var.region }