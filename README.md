# gitops-infra (Phase 1)

Goal: minimal EKS cluster + Argo CD + AWS Load Balancer Controller so the GitOps Deployer can test Argo sync + ALB Ingress end-to-end.

## Quick start

1) Ensure AWS auth works:
```bash
aws sts get-caller-identity
