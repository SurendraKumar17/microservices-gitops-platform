#!/usr/bin/env bash
# =============================================================
# bootstrap.sh
# Triggered automatically by Terraform null_resource after
# EKS + IAM are ready. Env vars passed by null_resource.
#
# Does:
#   1. Configure kubectl
#   2. Tag public subnets for ALB discovery
#   3. Install EKS Pod Identity Agent addon
#   4. Attach IAM policies to node role
#
# Does NOT:
#   - Fix IMDS hop limit (handled by launch template in modules/eks)
#   - Install any Helm charts (handled by modules/helm)
# =============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Verify required tools ──────────────────────────────────────
command -v aws     >/dev/null 2>&1 || err "aws cli not installed"
command -v kubectl >/dev/null 2>&1 || err "kubectl not installed"

# ── Validate env vars passed from Terraform null_resource ──────
: "${CLUSTER_NAME:?must be set}"
: "${REGION:?must be set}"
: "${VPC_ID:?must be set}"
: "${ACCOUNT_ID:?must be set}"

log "Cluster : $CLUSTER_NAME"
log "Region  : $REGION"
log "VPC     : $VPC_ID"
log "Account : $ACCOUNT_ID"

# =============================================================
# STEP 1 — Configure kubectl
# =============================================================
log "Configuring kubectl..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
kubectl get nodes || err "Cannot connect to cluster — check your kubeconfig"
log "kubectl configured ✅"

# =============================================================
# STEP 2 — Tag public subnets for ALB discovery
# Why: ALB controller uses these tags to auto-discover
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
  warn "No public subnets found matching '*public*' in VPC $VPC_ID — skipping"
else
  for subnet_id in $PUBLIC_SUBNETS; do
    aws ec2 create-tags \
      --resources "$subnet_id" \
      --tags \
        "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared" \
        "Key=kubernetes.io/role/elb,Value=1" \
      --region "$REGION"
    log "  Tagged $subnet_id"
  done
  log "Public subnets tagged ✅"
fi

# =============================================================
# STEP 3 — Install EKS Pod Identity Agent addon
# Why: Required for EKS Pod Identity to work.
#      Must be an EKS managed addon.
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
# DONE — Terraform will now proceed to install Helm releases
# =============================================================
echo ""
echo "================================================"
echo "  BOOTSTRAP COMPLETE"
echo "================================================"
echo "  Terraform will now install:"
echo "  → ALB Controller"
echo "  → EBS CSI Driver"
echo "  → Metrics Server"
echo "  → Cluster Autoscaler"
echo "  → ArgoCD"
echo "================================================"