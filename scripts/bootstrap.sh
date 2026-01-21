#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-jb-demo}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> AWS identity"
aws sts get-caller-identity >/dev/null

echo "==> Waiting for EKS control plane ACTIVE..."
for i in $(seq 1 60); do
  STATUS="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" --query "cluster.status" --output text 2>/dev/null || true)"
  if [ "$STATUS" = "ACTIVE" ]; then
    echo "EKS status: ACTIVE"
    break
  fi
  sleep 10
done
if [ "${STATUS:-}" != "ACTIVE" ]; then
  echo "EKS not ACTIVE (last status: ${STATUS:-unknown})"
  exit 1
fi

echo "==> Updating kubeconfig (refresh endpoint/CA)..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" >/dev/null

echo "==> Verifying kubectl connectivity..."
kubectl cluster-info >/dev/null

echo "==> Waiting for at least 1 Ready node..."
READY_COUNT=0
for i in $(seq 1 60); do
  READY_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')"
  if [ "$READY_COUNT" -ge 1 ]; then
    echo "Ready nodes: $READY_COUNT"
    break
  fi
  sleep 10
done
if [ "$READY_COUNT" -lt 1 ]; then
  echo "No Ready nodes."
  kubectl get nodes || true
  exit 1
fi

echo "==> Installing prerequisites (Helm repos)..."
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "==> Ensuring ServiceAccount for AWS Load Balancer Controller exists with IRSA annotation..."
ROLE_ARN="$(aws iam get-role --role-name "${CLUSTER_NAME}-alb-controller-irsa" --query 'Role.Arn' --output text)"
kubectl -n kube-system apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
EOF

VPC_ID="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"

echo "==> Installing/Upgrading AWS Load Balancer Controller..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

echo "==> Waiting for ALB controller deployment Ready..."
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=10m

echo "==> Waiting for webhook service endpoints..."
EP=""
for i in $(seq 1 60); do
  EP="$(kubectl -n kube-system get endpoints aws-load-balancer-webhook-service -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
  if [ -n "$EP" ]; then
    echo "Webhook endpoints ready: $EP"
    break
  fi
  sleep 5
done
if [ -z "$EP" ]; then
  echo "Webhook endpoints not ready."
  kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller -o wide || true
  kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=200 || true
  exit 1
fi

echo "==> Installing/Upgrading Argo CD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --set server.ingress.enabled=false

echo "==> Waiting for Argo CD pods..."
kubectl -n argocd rollout status deploy/argocd-server --timeout=10m
kubectl -n argocd get pods

echo "==> Applying Argo root app..."
kubectl apply -f "$REPO_ROOT/bootstrap/argocd-root-app.yaml"

echo "==> Done. Check Argo applications:"
kubectl -n argocd get applications || true

echo "==> Argo admin password (initial):"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
