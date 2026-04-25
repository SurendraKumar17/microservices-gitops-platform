output "alb_controller_role_arn"     { value = aws_iam_role.alb_controller.arn }
output "argocd_role_arn"             { value = aws_iam_role.argocd.arn }
output "ebs_csi_role_arn"            { value = aws_iam_role.ebs_csi.arn }
output "cluster_autoscaler_role_arn" { value = aws_iam_role.cluster_autoscaler.arn }