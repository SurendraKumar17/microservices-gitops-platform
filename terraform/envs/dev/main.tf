module "vpc" {
  source = "../../modules/vpc"

  region = var.region
  cidr   = "10.0.0.0/16"
  azs    = ["us-east-1a", "us-east-1b"]
  env    = "dev" 
}

module "eks" {
  source = "../../modules/eks"

  cluster_name = "dev-eks"
  subnet_ids   = module.vpc.private_subnets
  vpc_id       = module.vpc.vpc_id
  region       = var.region
}