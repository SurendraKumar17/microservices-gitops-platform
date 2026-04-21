module "vpc" {
  source = "../../modules/vpc"

  env              = "dev"
  vpc_cidr         = var.vpc_cidr
  azs              = var.azs
  private_subnets  = var.private_subnets
  public_subnets   = var.public_subnets
}

module "eks" {
  source     = "../../modules/eks"
  depends_on = [module.vpc]

  env          = "dev"
  cluster_name = var.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids
  region       = var.region
}

module "irsa" {
  source     = "../../modules/irsa"
  depends_on = [module.eks]

  env          = "dev"
  cluster_name = module.eks.cluster_name
  oidc_url     = module.eks.oidc_url
  region       = var.region
}

# Auto installs everything after EKS + IRSA ready
module "helm" {
  source     = "../../modules/helm"
  depends_on = [module.eks, module.irsa]

  cluster_name             = module.eks.cluster_name
  cluster_endpoint