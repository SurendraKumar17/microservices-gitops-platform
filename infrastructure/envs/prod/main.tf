module "vpc" {
  source = "../../modules/vpc"
  # ...
}

module "eks" {
  source     = "../../modules/eks"
  depends_on = [module.vpc]
  # ...
}

module "irsa" {
  source       = "../../modules/irsa"
  depends_on   = [module.eks]
  cluster_name = module.eks.cluster_name
  oidc_url     = module.eks.oidc_url
}

# This runs automatically after EKS + IRSA are ready
module "helm" {
  source     = "../../modules/helm"
  depends_on = [module.eks, module.irsa]

  cluster_name          = module.eks.cluster_name
  cluster_endpoint      = module.eks.cluster_endpoint
  cluster_ca            = module.eks.cluster_ca
  region                = var.region
  alb_controller_role_arn = module.irsa.alb_controller_role_arn
  ebs_csi_role_arn        = module.irsa.ebs_csi_role_arn
}