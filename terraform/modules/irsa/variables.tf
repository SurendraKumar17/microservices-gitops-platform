# Why separate IRSA module:
# ALB controller, ArgoCD, and future tools all need
# IRSA roles. Keeping them in one module means adding
# a new tool = adding one block here, not touching EKS.

variable "cluster_name"      {}
variable "oidc_provider_arn" {}
variable "oidc_provider_url" {}
variable "env"               {}
variable "project"           { default = "microservices" }
variable "alb_policy_json"   {}