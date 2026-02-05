#!/usr/bin/env bash
set -euo pipefail

# gitops-infra/scripts/teardown.sh
#
# Purpose:
#   Make terraform destroy deterministic by first deleting the Kubernetes resources
#   that cause AWS Load Balancer Controller to create AWS resources (ALBs, ENIs, SGs),
#   then waiting until AWS-side dependencies are gone, then running terraform destroy.
#
# Assumptions:
#   - REGION and CLUSTER_NAME are resolved from Terraform outputs/vars under TF_DIR (default: repo-root/terraform/infrastructure), or must be provided explicitly.
#   - Terraform state/outputs exist for the target cluster.
#   - Demo namespaces are jb-dev, jb-staging, jb-prod (adjust if needed).
#   - Your VPC is tagged Name="${CLUSTER_NAME}-vpc" OR can be read from terraform output vpc_id.
#
# Usage:
#   From repo root:
#     ./scripts/teardown.sh
#
# Optional env overrides:
#   REGION=us-east-1 CLUSTER_NAME=jb-demo TF_DIR=terraform/infrastructure NAMESPACES="jb-dev jb-staging jb-prod" ./scripts/teardown.sh
#

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

tf_resolved=""
vars_resolved=""

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
  echo "      REGION=us-east-1 CLUSTER_NAME=jb-demo ./scripts/teardown.sh" >&2
  exit 1
fi

log "Resolved config: TF_DIR=${TF_DIR} REGION=${REGION} CLUSTER_NAME=${CLUSTER_NAME}"

NAMESPACES="${NAMESPACES:-jb-dev jb-staging jb-prod}"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need aws
need kubectl
need terraform
need jq

# Ensure we can talk to the cluster (kubeconfig might be stale)
log "Updating kubeconfig for cluster ${CLUSTER_NAME} in ${REGION}"
aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}" >/dev/null

log "Sanity check: kubectl authorized for this cluster"
kubectl auth can-i get namespaces >/dev/null 2>&1 \
  || die "kubectl is not authorized for this cluster. Ensure your IAM principal is granted EKS access (access entry / cluster admin)."

log "Sanity check: kubectl can reach the cluster"
kubectl cluster-info >/dev/null

# Try to fetch VPC ID from terraform outputs if possible.
get_vpc_id() {
  local vpc=""
  if [[ -d "${TF_DIR}" ]]; then
    pushd "${TF_DIR}" >/dev/null
    if terraform output -json >/dev/null 2>&1; then
      vpc="$(terraform output -json | jq -r '.vpc_id.value // empty')"
    fi
    popd >/dev/null
  fi
  if [[ -n "${vpc}" ]]; then
    echo "${vpc}"
    return 0
  fi

  # Fallback: find VPC by Name tag
  aws ec2 describe-vpcs \
    --region "${REGION}" \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null | sed 's/None//'
}

VPC_ID="$(get_vpc_id || true)"

if [[ -z "${VPC_ID}" ]]; then
  log "WARNING: Could not determine VPC_ID (terraform output missing and Name tag lookup failed)."
  log "Teardown will still delete Kubernetes resources; AWS dependency wait will be skipped."
else
  log "Detected VPC_ID: ${VPC_ID}"
fi

# 1) Disable/Remove Argo-managed apps quickly (optional but helps stop recreation loops)
# If your root app exists, deleting it prevents Argo from re-creating resources while we tear down.
log "Attempting to delete all Argo CD apps to stop reconciliation"
kubectl -n argocd get applications.argoproj.io -o name 2>/dev/null | \
  xargs -r kubectl -n argocd delete --wait=false || true

# 2) Delete Ingresses first (fastest way to trigger ALB deletion)
log "Deleting all Ingress objects in demo namespaces (if any)"
for ns in ${NAMESPACES}; do
  if kubectl get ns "${ns}" >/dev/null 2>&1; then
    kubectl -n "${ns}" delete ingress --all --ignore-not-found=true --wait=false || true
  fi
done

# 3) Delete the demo namespaces (this removes Services, Deployments, etc.)
log "Deleting demo namespaces: ${NAMESPACES}"
for ns in ${NAMESPACES}; do
  if kubectl get ns "${ns}" >/dev/null 2>&1; then
    kubectl delete ns "${ns}" --wait=false || true
  fi
done

# 4) Wait for namespaces to terminate (bounded wait, then continue anyway)
log "Waiting for namespaces to terminate (up to 10 minutes)"
end_ns=$((SECONDS+600))

while true; do
  remaining=0
  for ns in ${NAMESPACES}; do
    phase="$(kubectl get ns "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ -n "${phase}" ]]; then
      remaining=$((remaining+1))
      log "Namespace still present: ${ns} phase=${phase}"
    fi
  done

  if [[ "${remaining}" -eq 0 ]]; then
    log "All demo namespaces removed."
    break
  fi

  if (( SECONDS > end_ns )); then
    log "WARNING: Some namespaces still exist after timeout. Dumping finalizers for debugging:"
    for ns in ${NAMESPACES}; do
      kubectl get ns "${ns}" -o jsonpath='{.metadata.name}{" finalizers="}{.spec.finalizers}{"\n"}' 2>/dev/null || true
    done
    break
  fi

  sleep 10
done

# 5) Wait for AWS Load Balancer Controller-managed security groups / ENIs to disappear.
# If these remain, subnet deletion will fail with DependencyViolation.
if [[ -n "${VPC_ID}" ]]; then
  log "Waiting for AWS dependencies created by AWS Load Balancer Controller to be cleaned up (up to 15 minutes)"
  log "This is primarily: SGs tagged ingress.k8s.aws/* or elbv2.k8s.aws/* in VPC ${VPC_ID}"

  end_aws=$((SECONDS+900))
  while true; do
    # Find SGs created/managed by the controller for Ingress stacks.
    sg_count="$(aws ec2 describe-security-groups \
      --region "${REGION}" \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query "length(SecurityGroups[?Tags[?Key=='ingress.k8s.aws/stack' || Key=='elbv2.k8s.aws/cluster']])" \
      --output text)"

    # Find ENIs that look like ELB-created in that VPC (covers ALB/NLB).
    eni_count="$(aws ec2 describe-network-interfaces \
      --region "${REGION}" \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query "length(NetworkInterfaces[?contains(Description, 'ELB ') || InterfaceType=='network_load_balancer'])" \
      --output text)"

    log "AWS dependency check: SGs(tagged)=${sg_count} ENIs(ELB-ish)=${eni_count}"

    if [[ "${sg_count}" == "0" && "${eni_count}" == "0" ]]; then
      log "AWS dependencies appear cleared."
      break
    fi

    if (( SECONDS > end_aws )); then
      log "WARNING: AWS dependencies still present after timeout."
      log "You can inspect remaining items:"
      log "  aws ec2 describe-security-groups --region ${REGION} --filters Name=vpc-id,Values=${VPC_ID}"
      log "  aws ec2 describe-network-interfaces --region ${REGION} --filters Name=vpc-id,Values=${VPC_ID}"
      break
    fi

    sleep 20
  done
fi

# 6) Now run terraform destroy for the infra.
log "Running terraform destroy in ${TF_DIR}"
pushd "${TF_DIR}" >/dev/null
terraform destroy -auto-approve
popd >/dev/null

log "Teardown complete."
