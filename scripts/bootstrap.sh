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
command -v aws       >/dev/null 2>&1 || err "aws cli not installed"
command -v kubectl   >/dev/null 2>&1 || err "kubectl not installed"
command -v helm      >/dev/null 2>&1 || err "helm not installed"
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
# STEP 2 — Tag public subnets for ALB discovery
# Why: ALB controller needs subnets tagged with cluster name
# and elb role to auto-discover them
# =============================================================
log "Tagging public subnets for ALB..."
PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:Name,Values=*public*" \
  --query 'Subnets[*].SubnetId' \
  --output text)

for subnet in $PUBLIC_SUBNETS; do
  aws ec2 create-tags \
    --resources "$subnet" \
    --tags \
      Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared \
      Key=kubernetes.io/role/elb,Value=1 \
    --region "$REGION"
  log "Tagged subnet $subnet"
done
log "Subnets tagged ✅"

# =============================================================
# STEP 3 — Install EKS Pod Identity Agent
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
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>/dev/null || true
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server 2>/dev/null || true
helm repo add ebs-csi https://kubernetes-sigs.github.io/aws-ebs-csi-driver 2>/dev/null || true
helm repo update

# ── Get node role and attach policies ──
log "Attaching policies to node role..."
NODE_ROLE=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "${CLUSTER_NAME}-nodes" \
  --query 'nodegroup.nodeRole' \
  --output text | cut -d'/' -f2)

aws iam attach-role-policy \
  --role-name "$NODE_ROLE" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_NAME}-alb-controller-policy" \
  2>/dev/null || log "ALB policy already attached"

aws iam attach-role-policy \
  --role-name "$NODE_ROLE" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" \
  2>/dev/null || log "EBS policy already attached"

log "Node role policies attached ✅"

# =============================================================
# STEP 4 — ALB Controller
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

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=aws-load-balancer-controller \
  -n kube-system --timeout=120s

log "ALB Controller ready ✅"

# =============================================================
# STEP 5 — EBS CSI Driver
# =============================================================
log "Installing EBS CSI Driver..."

# Clean up old service account if exists
kubectl delete sa ebs-csi-controller-sa -n kube-system 2>/dev/null || true

helm upgrade --install aws-ebs-csi-driver ebs-csi/aws-ebs-csi-driver \
  -n kube-system \
  --wait --timeout=5m

log "EBS CSI Driver ready ✅"

# =============================================================
# STEP 6 — Metrics Server
# =============================================================
log "Installing Metrics Server..."

helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --wait --timeout=3m

log "Metrics Server ready ✅"

# =============================================================
# STEP 7 — Cluster Autoscaler
# =============================================================
log "Installing Cluster Autoscaler..."

helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName="$CLUSTER_NAME" \
  --set awsRegion="$REGION" \
  --wait --timeout=5m

log "Cluster Autoscaler ready ✅"

# =============================================================
# STEP 8 — ArgoCD
# =============================================================
log "Installing ArgoCD..."

# Force delete stuck namespace if exists
kubectl delete namespace argocd --force --grace-period=0 2>/dev/null || true
sleep 10

kubectl create namespace argocd

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
# STEP 9 — ArgoCD Ingress
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
# STEP 10 — Register microservices with ArgoCD
# =============================================================
log "Waiting for ArgoCD CRDs to be ready..."
kubectl wait --for=condition=established \
  crd/applications.argoproj.io \
  --timeout=120s

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

kubectl get application microservices-dev -n argocd \
  || err "ArgoCD Application failed to register"

log "ArgoCD Application registered ✅"

# =============================================================
# SUMMARY
# =============================================================
echo ""
echo "================================================"
echo "  BOOTSTRAP COMPLETE"
echo "================================================"
echo "  ArgoCD UI : http://${ARGOCD_URL:-use port-forward}"
echo "  Username  : admin"
echo "  Password  : ${ARGOCD_PASS}"
echo ""
echo "  Port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "  Then open  : http://localhost:8080"
echo ""
echo "  Next: Merge develop → main for prod deploy"
echo "================================================"