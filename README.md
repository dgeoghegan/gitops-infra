# gitops-infra

This repository provisions the AWS foundation for a minimal GitOps demo: an EKS cluster with Argo CD and the AWS Load Balancer Controller, plus the durable AWS artifacts needed to build/push the demo app image from GitHub Actions.

Audience: a senior DevOps/platform engineer reviewing a portfolio project and expecting an end-to-end, reproducible run.

## Purpose and scope

What this repo is for:
- Create durable AWS artifacts used across demo runs:
  - ECR repository for the demo app image
  - GitHub Actions OIDC provider in AWS
  - IAM role/policy for GitHub Actions to push images to ECR (repo + branch restricted)
- Create ephemeral AWS infrastructure for a demo cluster:
  - VPC (2 AZs, public/private subnets, single NAT gateway)
  - EKS cluster + managed node group(s)
  - IRSA enabled
  - IAM policy + IRSA role for AWS Load Balancer Controller
- Bootstrap in-cluster components on top of that infrastructure:
  - AWS Load Balancer Controller (Helm)
  - Argo CD (Helm)
  - An Argo “root application” pointing at `gitops-release-controller`

What this repo is not for:
- It does not define application Kubernetes resources (Deployments/Ingress/Helm values). Those live in `gitops-release-controller`.
- It does not implement the app build pipeline. That lives in `versioned-app`.
- It does not provide a full platform (no autoscaling, observability stack, policy-as-code, canaries, etc.).

## High-level architecture

Three layers, intentionally separated:

1) Durable artifacts (Terraform root: `terraform/artifacts/`)
- ECR repository: `versioned-app` (immutable tags; protected from accidental destroy)
- GitHub Actions OIDC provider: `token.actions.githubusercontent.com`
- IAM role for GitHub Actions to push images to ECR, restricted to:
  - repo `${github_org}/${github_repo_versioned_app}`
  - branch `refs/heads/${github_branch}`
  - tags `refs/tags/v*`

2) Ephemeral infrastructure (Terraform root: `terraform/infrastructure/`)
- VPC:
  - 2 AZs
  - public + private subnets
  - single NAT gateway
  - subnet tags for Kubernetes ELB integration
- EKS:
  - Kubernetes 1.30
  - public API endpoint access enabled
  - managed node group in private subnets
  - IRSA enabled
- IAM for AWS Load Balancer Controller:
  - controller policy from `terraform/infrastructure/iam/aws-load-balancer-controller-policy.json`
  - IRSA role restricted to service account `kube-system/aws-load-balancer-controller`

3) Bootstrapped in-cluster components (script: `scripts/bootstrap.sh`)
- AWS Load Balancer Controller installed via Helm, using IRSA role
- Argo CD installed via Helm (server is ClusterIP; ingress disabled)
- Root Argo Application applied from `bootstrap/argocd-root-app.yaml`

## Prerequisites

Local tools:
- Terraform >= 1.5
- AWS CLI v2
- kubectl (compatible with EKS 1.30)
- Helm v3
- jq
- bash

AWS account and permissions:
- Ability to create/manage: VPC, EKS, IAM roles/policies, ECR, and (for the controller) ELB-related resources
- Terraform remote state backend must exist and be accessible (you provide your own):
  - S3 bucket for state
  - DynamoDB table for state locking (recommended)

GitHub access assumptions:
- The demo assumes the following repos exist and are readable:
  - `dgeoghegan/versioned-app`
  - `dgeoghegan/gitops-release-controller`

## Configuration knobs (minimal)

Terraform variables (defaults shown):
- `region`: `us-east-1`
- `cluster_name`: `jb-demo`
- `vpc_cidr`: `10.0.0.0/16`
- Node group sizing:
  - `node_instance_types`: `["t3.small"]`
  - `node_desired_size`: `2`
  - `node_min_size`: `2`
  - `node_max_size`: `3`
- `tags`: `Project=gitops-demo`, `Phase=phase1` (plus anything you add)

Artifacts-only variables (OIDC/IAM scope):
- `github_org`: `dgeoghegan`
- `github_repo_versioned_app`: `versioned-app`
- `github_branch`: `main`
- `ecr_repository_name`: `versioned-app`

Script environment variables (optional overrides):
- `REGION`, `CLUSTER_NAME`
- `TF_DIR` (if your Terraform roots move later)
- `NAMESPACES` (teardown only; defaults to `jb-dev jb-staging jb-prod`)

## Quickstart (copy/paste)

From repo root:

```bash
# 0) Configure Terraform backend (one-time)
cp backend.hcl.example backend.hcl
```

Edit `backend.hcl` and set:
- `bucket` — your S3 bucket for Terraform state
- `region` — the AWS region of that bucket
- `dynamodb_table` — your DynamoDB table for state locking

```bash
# 1) Sanity check credentials
aws sts get-caller-identity

# 2) Durable artifacts (ECR + GitHub OIDC + CI role)
cd terraform/artifacts
terraform init \
  -backend-config=../../backend.hcl \
  -backend-config="key=gitops-infra/artifacts/terraform.tfstate"
terraform apply

# 3) Ephemeral infra (VPC + EKS + IRSA role for ALB controller)
cd ../infrastructure
terraform init \
  -backend-config=../../backend.hcl \
  -backend-config="key=gitops-infra/infrastructure/terraform.tfstate"
terraform apply

# 4) Bootstrap in-cluster components (ALB controller + Argo CD + root Argo app)
cd ../../scripts
./bootstrap.sh
```

## Detailed runbook

### A) One-time durable setup: `terraform/artifacts/`

What it creates:
- ECR repository `versioned-app`:
  - tag mutability: IMMUTABLE
  - `prevent_destroy = true`
- AWS IAM OIDC provider for GitHub Actions
- IAM role `github-actions-ecr-push` restricted to:
  - `repo:${github_org}/${github_repo_versioned_app}:ref:refs/heads/${github_branch}`
  - `repo:${github_org}/${github_repo_versioned_app}:ref:refs/tags/v*`
- IAM policy granting least-privilege ECR push/pull to the single repo, plus `ecr:GetAuthorizationToken` on `*` (required by ECR auth)

Commands:
```bash
cd terraform/artifacts
terraform init \
  -backend-config=../../backend.hcl \
  -backend-config="key=gitops-infra/artifacts/terraform.tfstate"
terraform apply

```

Useful outputs:
- `ecr_repository_url`
- `github_actions_ecr_push_role_arn`

### B) Infra provisioning: `terraform/infrastructure/`

What it creates:
- VPC spanning 2 AZs, with public/private subnets and a single NAT gateway
- EKS cluster (1.30) with a managed node group
- IRSA enabled
- IAM policy + IRSA role for AWS Load Balancer Controller, scoped to:
  - `system:serviceaccount:kube-system:aws-load-balancer-controller`

Commands:
```bash
cd terraform/infrastructure
terraform init \
  -backend-config=../../backend.hcl \
  -backend-config="key=gitops-infra/infrastructure/terraform.tfstate"
terraform apply
```

Useful outputs:
- `cluster_name`, `region`
- `vpc_id`, `public_subnet_ids`, `private_subnet_ids`
- `alb_controller_role_arn`

### C) Bootstrap: `scripts/bootstrap.sh`

What it does:
- Resolves `REGION` and `CLUSTER_NAME` (env override first, otherwise Terraform outputs, otherwise TF variable defaults)
- Updates kubeconfig for the cluster and verifies kubectl connectivity
- Waits for:
  - EKS control plane status ACTIVE
  - at least one Ready node
- Installs/upgrades AWS Load Balancer Controller (Helm):
  - creates/updates ServiceAccount `kube-system/aws-load-balancer-controller`
  - annotates it with IRSA role `${CLUSTER_NAME}-alb-controller-irsa`
  - installs chart `eks/aws-load-balancer-controller`
- Installs/upgrades Argo CD (Helm):
  - namespace `argocd`
  - server service type: ClusterIP
  - ingress disabled
- Applies the Argo root app: `bootstrap/argocd-root-app.yaml`
- Prints the initial Argo admin password

Run it:
```bash
cd scripts
./bootstrap.sh
```

Root app definition (high-level):
- Name: `root-apps`
- Source repo: `gitops-release-controller` (main)
- Path: `argocd/applications`
- Sync policy: automated, prune, self-heal

### D) Verification

1) Confirm cluster access and nodes:
```bash
kubectl cluster-info
kubectl get nodes -o wide
```

2) Confirm AWS Load Balancer Controller is running:
```bash
kubectl -n kube-system get deploy aws-load-balancer-controller
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=5m
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller -o wide
```

3) Confirm Argo CD is running:
```bash
kubectl -n argocd get pods
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
kubectl -n argocd get svc
```

4) Reach the Argo CD UI (port-forward only)

Argo CD server is ClusterIP with ingress disabled, so access is via port-forward:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

Open:
- http://localhost:8080

Get the initial admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

5) Confirm Argo Applications were created and are syncing:

```bash
kubectl -n argocd get applications
kubectl -n argocd get app root-apps -o wide
```

6) Find the demo app endpoint (ALB)

Once `gitops-release-controller` applies the app Ingress and the controller reconciles it, read the ALB hostname:

```bash
kubectl get ingress -A

# If your app ingress lives in jb-dev (common in this demo), for example:
kubectl -n jb-dev get ingress
kubectl -n jb-dev get ingress <INGRESS_NAME> -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
```

## Teardown

Teardown is **best-effort and bounded**. It is designed to make `terraform destroy` succeed reliably by first deleting Kubernetes resources that trigger the AWS Load Balancer Controller (ALBs, ENIs, security groups), then waiting (with timeouts) for AWS-side dependencies to clear.

What teardown does:
- Updates kubeconfig for the target cluster
- Deletes Argo CD Applications (to stop reconciliation loops)
- Deletes all Ingress resources in the demo namespaces
- Deletes the demo namespaces (`jb-dev jb-staging jb-prod` by default)
- Waits (bounded) for namespaces to terminate
- Waits (bounded) for common AWS dependencies (SGs/ENIs) associated with controller-managed load balancers to disappear
- Runs `terraform destroy` for the infrastructure root

What teardown does not guarantee:
- Immediate cleanup of all AWS resources. ALB/ENI/SG deletion is subject to AWS eventual consistency and can exceed the timeout.
- Automatic cleanup if cluster state or AWS state has already diverged from Terraform (e.g., manual edits, partial applies).

If teardown hits a timeout:
- The script will continue and/or emit inspect commands.
- If `terraform destroy` fails with dependency errors, wait a few minutes and re-run `scripts/teardown.sh`, or use the printed AWS CLI commands to identify remaining dependencies.

Run teardown from repo root:
```bash
scripts/teardown.sh
```

Optional overrides:
```bash
REGION=us-east-1 CLUSTER_NAME=jb-demo TF_DIR=terraform/infrastructure \
NAMESPACES="jb-dev jb-staging jb-prod" \
scripts/teardown.sh
```

Notes:
- Teardown waits (bounded) for namespaces to terminate and for controller-created SGs/ENIs to disappear.
- If AWS dependencies remain after the timeout, the script prints AWS CLI commands to inspect them. In that case, `terraform destroy` may still fail until the dependencies clear.

## Security notes (concise)

- Least-privilege intent:
  - GitHub Actions role only allows ECR push/pull to a single repo, plus `ecr:GetAuthorizationToken` on `*` (required).
  - Trust policy restricts assumption to a specific GitHub repo, branch, and tags `v*`.
- IRSA:
  - AWS Load Balancer Controller runs with a Kubernetes service account annotated with a dedicated IAM role.
  - The IRSA trust policy restricts the role to the exact service account `kube-system/aws-load-balancer-controller`.
- Secrets:
  - No long-lived AWS access keys are created by these Terraform configs.
  - Argo initial admin password is stored in-cluster as `argocd-initial-admin-secret`.

## Reviewer in 10 minutes

Related repos (source of truth for app delivery):
- `gitops-release-controller`: Argo Applications, env values, and the “Cannon” workflow that updates desired image tags via PRs.
- `versioned-app`: GitHub Actions build/push workflow that publishes immutable image tags to ECR.

Expected demo loop:
1) Merge to `versioned-app` main (or create a `v*` tag) to build/push a new immutable image tag to ECR.
2) The release controller updates the desired image tag in Git (PR), then merge triggers Argo sync.
3) Verify the live app reports the new version via the ALB endpoint.
4) Roll back by reverting the Git change (image tag) and letting Argo reconcile back.

For convenience, the repo URLs are:

```text
https://github.com/dgeoghegan/gitops-release-controller
https://github.com/dgeoghegan/versioned-app
https://github.com/dgeoghegan/gitops-infra
```

## Optional future improvements (non-blocking)

- Normalize script defaults for `TF_DIR` so bootstrap/teardown don’t drift when directories move.
- Add a small `scripts/status.sh` helper that prints cluster, Argo apps, ingress hostname(s), and current image tag.
- Rename demo namespaces to something more “boring standard” once the repo set stabilizes.
