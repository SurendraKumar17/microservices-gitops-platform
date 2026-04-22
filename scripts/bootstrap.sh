#!/usr/bin/env bash
# =============================================================
# bootstrap.sh
# Run ONCE after terraform apply
# Installs: ALB Controller → EBS CSI → Cluster Autoscaler
#           → Metrics Server → ArgoCD
# =============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Verify required tools
command -v aws     >/dev/null 2>&1 || err "aws cli not installed"
command -v kubectl >/dev/null 2>&1 || err "kubectl not installed"
command -v helm    >/dev/null 2>&1 || err "helm not installed"
command -v terraform >/dev/null 2>&1 || err "terraform not installed"

# ── Read from Terraform outputs ──
TERRAFORM_DIR="$(dirname "$0")/../infrastructure/envs/dev"
log "Reading Terraform outputs..."
cd "$TERRAFORM_DIR"

CLUSTER_NAME=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
VPC_ID=$(terraform output -raw vpc_id)

log "Cluster: $CLUSTER_NAME | Region: $REGION | Account: $ACCOUNT_ID"
cd - > /dev/null

# ── Configure kubectl ──
log "Configuring kubectl..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
kubectl get nodes || err "Cannot connect to cluster"

# =============================================================
# STEP 1 — Fix IMDS hop limit on all nodes
# Why: Default hop limit is 1, pods need 2 to reach
# EC2 metadata service for IAM credentials
# =============================================================
log "Fixing IMDS hop limit on nodes..."

INSTANCES=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text)

for i in $INSTANCES; do
  aws ec2 modify-instance-metadata-options \
    --instance-id "$i" \
    --http-put-response-hop-limit 2 \
    --http-endpoint enabled \
    --region "$REGION" > /dev/null
  log "Fixed IMDS on $i"
done

log "IMDS hop limit fixed ✅"

# =============================================================
# STEP 2 — Install EKS Pod Identity Agent
# =============================================================
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

# ── Attach ALB policy to node role ──
# Why: Simplest and most reliable credential method
log "Attaching ALB policy to node role..."
NODE_ROLE=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "${CLUSTER_NAME}-nodes" \
  --query 'nodegroup.nodeRole' \
  --output text | cut -d'/' -f2)

aws iam attach-role-policy \
  --role-name "$NODE_ROLE" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_NAME}-alb-controller-policy" \
  2>/dev/null || log "Policy already attached"

log "Node role policy attached ✅"

# =============================================================
# STEP 3 — ALB Controller
# =============================================================
log "Installing ALB Controller..."

# Clean up any previous failed install
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
kubectl delete sa aws-load-balancer-controller -n kube-system 2>/dev/null || true
sleep 5

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=true \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set replicaCount=1 \
  --wait --timeout=5m

log "Waiting for ALB Controller to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=aws-load-balancer-controller \
  -n kube-system --timeout=120s

log "ALB Controller ready ✅"

# =============================================================
# STEP 4 — EBS CSI Driver
# =============================================================
log "Installing EBS CSI Driver..."

aws iam attach-role-policy \
  --role-name "$NODE_ROLE" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" \
  2>/dev/null || log "EBS policy already attached"

helm upgrade --install aws-ebs-csi-driver ebs-csi/aws-ebs-csi-driver \
  -n kube-system \
  --wait --timeout=5m

log "EBS CSI Driver ready ✅"

# =============================================================
# STEP 5 — Metrics Server
# =============================================================
log "Installing Metrics Server..."

helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --wait --timeout=3m

log "Metrics Server ready ✅"

# =============================================================
# STEP 6 — Cluster Autoscaler
# =============================================================
log "Installing Cluster Autoscaler..."

helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName="$CLUSTER_NAME" \
  --set awsRegion="$REGION" \
  --wait --timeout=5m

log "Cluster Autoscaler ready ✅"

# =============================================================
# STEP 7 — ArgoCD
# =============================================================
log "Installing ArgoCD..."

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  --set server.service.type=ClusterIP \
  --set configs.params."server\.insecure"=true \
  --set server.replicas=1 \
  --set repoServer.replicas=1 \
  --wait --timeout=15m

log "ArgoCD ready ✅"

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

# =============================================================
# STEP 8 — ArgoCD Ingress
# =============================================================
log "Creating ArgoCD Ingress..."

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTP
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF

log "Waiting for ALB DNS (~2 mins)..."
sleep 60

ARGOCD_URL=""
for i in {1..10}; do
  ARGOCD_URL=$(kubectl get ingress argocd-ingress -n argocd \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$ARGOCD_URL" ]; then
    break
  fi
  log "Waiting for ALB... attempt $i/10"
  sleep 15
done

log "ArgoCD Ingress ready ✅"

# =============================================================
# STEP 9 — Register microservices with ArgoCD
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
echo "  ArgoCD UI : http://${ARGOCD_URL}"
echo "  Username  : admin"
echo "  Password  : ${ARGOCD_PASS}"
echo ""
echo "  Next: Merge develop → main for prod deploy"
echo "================================================"