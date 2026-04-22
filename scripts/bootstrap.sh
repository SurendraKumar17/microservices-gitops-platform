#!/usr/bin/env bash
# =============================================================
# bootstrap.sh
# Run ONCE after terraform apply
# Installs: ALB Controller → EBS CSI → Cluster Autoscaler
#           → Metrics Server → ArgoCD
# Each step waits for previous to be healthy before proceeding
# =============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Read from Terraform outputs ──
TERRAFORM_DIR="$(dirname "$0")/../infrastructure/envs/dev"
log "Reading Terraform outputs..."
cd "$TERRAFORM_DIR"

CLUSTER_NAME=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw region)
ALB_ROLE_ARN=$(terraform output -raw alb_controller_role_arn)
ARGOCD_ROLE_ARN=$(terraform output -raw argocd_role_arn)

log "Cluster: $CLUSTER_NAME | Region: $REGION"
cd - > /dev/null

# ── Configure kubectl ──
log "Configuring kubectl..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
kubectl get nodes || err "Cannot connect to cluster"

# ── Install EKS Pod Identity Agent ──
# Required for IRSA to work — injects AWS credentials into pods
log "Installing EKS Pod Identity Agent..."
aws eks create-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name eks-pod-identity-agent \
  --region "$REGION" 2>/dev/null || log "Pod Identity Agent already installed"

aws eks wait addon-active \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name eks-pod-identity-agent \
  --region "$REGION"

log "Pod Identity Agent ready ✅"

# ── Add Helm repos ──
log "Adding Helm repos..."
helm repo add eks https://aws.github.io/eks-charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
helm repo add ebs-csi https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

# =============================================================
# STEP 1 — ALB Controller
# Must be first — other charts create Services that need it
# =============================================================
log "Installing ALB Controller..."

kubectl create namespace kube-system --dry-run=client -o yaml | kubectl apply -f -
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: ${ALB_ROLE_ARN}
EOF

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" \
  --set vpcId=$(terraform -chdir=$TERRAFORM_DIR output -raw vpc_id) \
  --set replicaCount=1 \
  --atomic \
  --wait --timeout=5m

log "Waiting for ALB Controller to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=aws-load-balancer-controller \
  -n kube-system --timeout=120s

log "ALB Controller ready ✅"

# =============================================================
# STEP 2 — EBS CSI Driver
# Required for persistent volumes (databases etc)
# =============================================================
log "Installing EBS CSI Driver..."

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ebs-csi-controller-sa
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-ebs-csi
EOF

helm upgrade --install aws-ebs-csi-driver ebs-csi/aws-ebs-csi-driver \
  -n kube-system \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=ebs-csi-controller-sa \
  --atomic \
  --wait --timeout=5m

log "EBS CSI Driver ready ✅"

# =============================================================
# STEP 3 — Metrics Server
# Required for HPA (Horizontal Pod Autoscaler)
# =============================================================
log "Installing Metrics Server..."

helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --atomic \
  --wait --timeout=3m

log "Metrics Server ready ✅"

# =============================================================
# STEP 4 — Cluster Autoscaler
# Automatically adds/removes nodes based on pod demand
# =============================================================
log "Installing Cluster Autoscaler..."

helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName="$CLUSTER_NAME" \
  --set awsRegion="$REGION" \
  --atomic \
  --wait --timeout=5m

log "Cluster Autoscaler ready ✅"

# =============================================================
# STEP 5 — ArgoCD
# Install LAST — needs ALB controller webhook to be running
# =============================================================
log "Installing ArgoCD..."

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    eks.amazonaws.com/role-arn: ${ARGOCD_ROLE_ARN}
EOF

helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  --set server.service.type=ClusterIP \
  --set configs.params."server\.insecure"=true \
  --set server.replicas=2 \
  --set repoServer.replicas=2 \
  --set serviceAccount.create=false \
  --set serviceAccount.name=argocd-server \
  --atomic \
  --wait --timeout=10m

log "ArgoCD ready ✅"

# Get password
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

# =============================================================
# STEP 6 — Register microservices with ArgoCD
# =============================================================
log "Registering apps with ArgoCD..."

cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: microservices-dev
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/SurendraKumar17/microservices-gitops-platform
    targetRevision: develop
    path: helm/booking-app
    helm:
      valueFiles:
        - ../../gitops/environments/dev/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

log "ArgoCD Application registered ✅"

# =============================================================
# SUMMARY
# =============================================================
echo ""
echo "================================================"
echo "  BOOTSTRAP COMPLETE"
echo "================================================"
echo "  ArgoCD username : admin"
echo "  ArgoCD password : $ARGOCD_PASS"
echo ""
echo "  Access ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "  Then open: http://localhost:8080"
echo ""
echo "  Next: Add Ingress for external access"
echo "================================================"