variable "region" {
  default = "us-east-1"
}

variable "cluster_name" {
  default = "prod-eks-cluster"
}

variable "vpc_cidr" {
  default = "10.1.0.0/16"
}

variable "azs" {
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "private_subnets" {
  default = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
}

variable "public_subnets" {
  default = ["10.1.101.0/24", "10.1.102.0/24", "10.1.103.0/24"]
}