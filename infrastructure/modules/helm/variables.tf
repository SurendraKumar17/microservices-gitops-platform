# =============================================================
# modules/helm/variables.tf
# =============================================================

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID — passed to ALB controller for subnet discovery"
  type        = string
}

# ── IAM roles (IRSA) ──────────────────────────────────────────

variable "alb_controller_role_arn" {
  description = "IAM role ARN for the ALB controller (created in modules/iam)"
  type        = string
}

variable "ebs_csi_role_arn" {
  description = "IAM role ARN for the EBS CSI driver (created in modules/iam)"
  type        = string
}

variable "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for the Cluster Autoscaler (created in modules/iam)"
  type        = string
}

# ── Chart versions (pin these; never use 'latest') ────────────

variable "alb_controller_version" {
  description = "Helm chart version for aws-load-balancer-controller"
  type        = string
  default     = "1.8.1"
}

variable "ebs_csi_version" {
  description = "Helm chart version for aws-ebs-csi-driver"
  type        = string
  default     = "2.32.0"
}

variable "metrics_server_version" {
  description = "Helm chart version for metrics-server"
  type        = string
  default     = "3.12.1"
}

variable "cluster_autoscaler_version" {
  description = "Helm chart version for cluster-autoscaler"
  type        = string
  default     = "9.37.0"
}

variable "argocd_version" {
  description = "Helm chart version for argo-cd"
  type        = string
  default     = "7.3.4"
}

# ── Replica counts (override per env) ─────────────────────────

variable "alb_controller_replica_count" {
  description = "ALB controller replicas — 1 for dev, 2 for prod"
  type        = number
  default     = 1
}

variable "argocd_server_replicas" {
  description = "ArgoCD server replicas — 1 for dev, 2 for prod"
  type        = number
  default     = 1
}

variable "argocd_repo_server_replicas" {
  description = "ArgoCD repo-server replicas — 1 for dev, 2 for prod"
  type        = number
  default     = 1
}