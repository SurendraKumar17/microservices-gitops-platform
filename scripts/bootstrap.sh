#!/usr/bin/env bash
# =============================================================
# bootstrap.sh
# Run ONCE after terraform apply
# Purpose: AWS-level pre-flight config only.
#          Helm chart installs are handled by Terraform (modules/helm).
#
# Does:
#   1. Fix IMDS hop limit on all EKS nodes
#   2. Tag public subnets for ALB discovery
#   3. Install EKS Pod Identity Agent addon
#   4. Attach IAM policies to node role
#   5. Configure kubectl
#
# Does NOT: install any Helm charts (Terraform owns those)
# =============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Verify required tools ──────────────────────────────────────
command -v aws       >/dev/null 2>&1 || err "aws cli not installed"
command -v kubectl   >/dev/null 2>&1 || err "kubectl not installed"
command -v terraform >/dev/null 2>&1 || err "terraform not installed"

# ── Read Terraform outputs ─────────────────────────────────────
TERRAFORM_DIR="$(dirname "$0")/../infrastructure/envs/dev"
log "Reading Terraform outputs from: $TERRAFORM_DIR"
cd "$TERRAFORM_DIR"

CLUSTER_NAME=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw region)
VPC_ID=$(terraform output -raw vpc_id)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

log "Cluster : $CLUSTER_NAME"
log "Region  : $REGION"
log "Account : $ACCOUNT_ID"
log "VPC     : $VPC_ID"
cd - > /dev/null

# =============================================================
# STEP 1 — Configure kubectl
# =============================================================
log "Configuring kubectl..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
kubectl get nodes || err "Cannot connect to cluster — check your kubeconfig"
log "kubectl configured ✅"

# =============================================================
# STEP 2 — Fix IMDS hop limit on all nodes
# Why: Default hop limit is 1. Pods need hop limit 2 to reach
#      the EC2 metadata service for IRSA/IAM credentials.
# =============================================================
log "Fixing IMDS hop limit on nodes..."
INSTANCES=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text \
  --region "$REGION")

if [ -z "$INSTANCES" ]; then
  warn "No running instances found for cluster $CLUSTER_NAME — skipping IMDS fix"
else
  for instance_id in $INSTANCES; do
    aws ec2 modify-instance-metadata-options \
      --instance-id "$instance_id" \
      --http-put-response-hop-limit 2 \
      --http-endpoint enabled \
      --region "$REGION" > /dev/null
    log "  Fixed IMDS on $instance_id"
  done
  log "IMDS hop limit fixed ✅"
fi

# =============================================================
# STEP 3 — Tag public subnets for ALB discovery
# Why: The ALB controller uses these tags to auto-discover
#      which subnets to place internet-facing load balancers in.
# =============================================================
log "Tagging public subnets for ALB..."
PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:Name,Values=*public*" \
  --query 'Subnets[*].SubnetId' \
  --output text \
  --region "$REGION")

if [ -z "$PUBLIC_SUBNETS" ]; then
  warn "No public subnets found matching '*public*' in VPC $VPC_ID — skipping subnet tagging"
else
  for subnet_id in $PUBLIC_SUBNETS; do
    aws ec2 create-tags \
      --resources "$subnet_id" \
      --tags \
        "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared" \
        "Key=kubernetes.io/role/elb,Value=1" \
      --region "$REGION"
    log "  Tagged subnet $subnet_id"
  done
  log "Public subnets tagged ✅"
fi

# =============================================================
# STEP 4 — Install EKS Pod Identity Agent addon
# Why: Required for EKS Pod Identity (the modern replacement
#      for IRSA) to work. Must be an EKS managed addon.
# =============================================================
log "Installing EKS Pod Identity Agent addon..."
ADDON_STATUS=$(aws eks describe-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name eks-pod-identity-agent \
  --region "$REGION" \
  --query 'addon.status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$ADDON_STATUS" = "ACTIVE" ]; then
  log "Pod Identity Agent already ACTIVE — skipping"
else
  aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name eks-pod-identity-agent \
    --region "$REGION"

  log "Waiting for Pod Identity Agent to become active..."
  aws eks wait addon-active \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name eks-pod-identity-agent \
    --region "$REGION"
  log "Pod Identity Agent ready ✅"
fi

# =============================================================
# STEP 5 — Attach IAM policies to node role
# Why: Node IAM role needs these policies so the ALB controller
#      and EBS CSI driver can make AWS API calls from pods.
#      Terraform creates the policies; this attaches them.
# =============================================================
log "Attaching IAM policies to node role..."
NODE_ROLE=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "${CLUSTER_NAME}-nodes" \
  --query 'nodegroup.nodeRole' \
  --output text \
  --region "$REGION" | awk -F'/' '{print $NF}')

log "  Node role: $NODE_ROLE"

# ALB controller policy (created by Terraform)
aws iam attach-role-policy \
  --role-name "$NODE_ROLE" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_NAME}-alb-controller-policy" \
  2>/dev/null && log "  Attached ALB controller policy" \
  || log "  ALB controller policy already attached"

# EBS CSI AWS managed policy
aws iam attach-role-policy \
  --role-name "$NODE_ROLE" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" \
  2>/dev/null && log "  Attached EBS CSI policy" \
  || log "  EBS CSI policy already attached"

log "Node role policies attached ✅"

# =============================================================
# DONE
# Helm charts (ALB controller, EBS CSI, Autoscaler, Metrics
# Server, ArgoCD) are installed by Terraform via modules/helm.
# Run: terraform apply  (from infrastructure/envs/dev)
# =============================================================
echo ""
echo "================================================"
echo "  BOOTSTRAP COMPLETE"
echo "================================================"
echo "  AWS pre-flight config done."
echo ""
echo "  Next steps:"
echo "  1. cd infrastructure/envs/dev"
echo "  2. terraform apply"
echo "     → installs ALB controller, EBS CSI, Autoscaler,"
echo "       Metrics Server, and ArgoCD via Helm"
echo ""
echo "  After terraform apply, get ArgoCD credentials:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret \\"
echo "    -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "  Port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "  Then open  : http://localhost:8080  (admin / <password above>)"
echo "================================================"