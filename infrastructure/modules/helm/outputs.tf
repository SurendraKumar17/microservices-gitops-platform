output "argocd_hostname" {
  description = "ALB hostname for ArgoCD"
  value       = try(kubernetes_ingress_v1.argocd.status[0].load_balancer[0].ingress[0].hostname, "")
}