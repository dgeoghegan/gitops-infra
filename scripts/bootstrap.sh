#!/usr/bin/env bash
set -euo pipefail

# ---------- config resolution (shared) ----------

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TF_DIR="${TF_DIR:-${REPO_ROOT}/terraform/infrastructure}"

log() { printf "\n[%s] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

tf_output_json() {
  [[ -d "${TF_DIR}" ]] || return 1
  pushd "${TF_DIR}" >/dev/null || return 1
  terraform output -json 2>/dev/null
  local rc=$?
  popd >/dev/null || true
  return $rc
}

# Very small HCL "default =" extractor (best-effort). Not a full parser.
hcl_default() {
  # hcl_default <var_name> <file>
  local var="$1" file="$2"
  [[ -f "$file" ]] || return 1
  # looks for:
  # variable "region" { ... default = "us-east-1" ... }
  awk -v v="$var" '
    $0 ~ "variable[[:space:]]+\""v"\"" {invar=1}
    invar && $0 ~ /default[[:space:]]*=/ {
      # strip everything up to '=' then trim whitespace/quotes
      sub(/.*default[[:space:]]*=[[:space:]]*/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      gsub(/^"|"$/, "", $0)
      print $0
      exit
    }
    invar && $0 ~ /}/ {invar=0}
  ' "$file"
}

resolve_from_tf() {
  local out
  out="$(tf_output_json || true)"
  [[ -n "$out" ]] || return 1

  # These output names must match what you define in outputs.tf.
  # Suggested outputs:
  # - cluster_name
  # - region
  echo "$out" | jq -r '
    {
      region: (.region.value // empty),
      cluster_name: (.cluster_name.value // empty)
    } | @json
  ' 2>/dev/null
}

resolve_from_vars() {
  # Prefer terraform.tfvars if you have it; then variables.tf defaults
  local region="" cluster=""

  if [[ -f "${TF_DIR}/terraform.tfvars" ]]; then
    region="$(awk -F= '/^[[:space:]]*region[[:space:]]*=/ {gsub(/["[:space:]]/, "", $2); print $2; exit}' "${TF_DIR}/terraform.tfvars" || true)"
    cluster="$(awk -F= '/^[[:space:]]*cluster_name[[:space:]]*=/ {gsub(/["[:space:]]/, "", $2); print $2; exit}' "${TF_DIR}/terraform.tfvars" || true)"
  fi

  if [[ -z "${region}" ]]; then
    region="$(hcl_default region "${TF_DIR}/variables.tf" || true)"
  fi
  if [[ -z "${cluster}" ]]; then
    cluster="$(hcl_default cluster_name "${TF_DIR}/variables.tf" || true)"
  fi

  jq -n --arg region "$region" --arg cluster_name "$cluster" \
    '{region:$region, cluster_name:$cluster_name}'
}

# Final resolution
REGION="${REGION:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"

if [[ -z "${REGION}" || -z "${CLUSTER_NAME}" ]]; then
  if have terraform && have jq; then
    tf_resolved="$(resolve_from_tf || true)"
    if [[ -n "${tf_resolved}" ]]; then
      [[ -z "${REGION}" ]] && REGION="$(echo "${tf_resolved}" | jq -r '.region // empty')"
      [[ -z "${CLUSTER_NAME}" ]] && CLUSTER_NAME="$(echo "${tf_resolved}" | jq -r '.cluster_name // empty')"
    fi
  fi
fi

if [[ -z "${REGION}" || -z "${CLUSTER_NAME}" ]]; then
  vars_resolved="$(resolve_from_vars || true)"
  [[ -z "${REGION}" ]] && REGION="$(echo "${vars_resolved}" | jq -r '.region // empty')"
  [[ -z "${CLUSTER_NAME}" ]] && CLUSTER_NAME="$(echo "${vars_resolved}" | jq -r '.cluster_name // empty')"
fi

if [[ -z "${REGION}" || -z "${CLUSTER_NAME}" ]]; then
  echo "ERROR: Could not resolve REGION/CLUSTER_NAME." >&2
  echo "Checked (in order):" >&2
  echo "  1) terraform outputs in TF_DIR=${TF_DIR}" >&2
  echo "  2) ${TF_DIR}/terraform.tfvars and ${TF_DIR}/variables.tf defaults" >&2
  echo "" >&2
  echo "Fix one of:" >&2
  echo "  - Set TF_DIR to the correct terraform root (expected: \$REPO_ROOT/terraform/infrastructure)" >&2
  echo "  - Or export REGION and CLUSTER_NAME explicitly:" >&2
  echo "      REGION=us-east-1 CLUSTER_NAME=jb-demo ./scripts/bootstrap.sh" >&2
  exit 1
fi

log "Resolved config: TF_DIR=${TF_DIR} REGION=${REGION} CLUSTER_NAME=${CLUSTER_NAME}"

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
