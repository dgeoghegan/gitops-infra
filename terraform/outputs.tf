output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}

output "github_actions_ecr_push_role_arn" {
  description = "Role ARN assumed by GitHub Actions (versioned-app) to push images to ECR"
  value       = aws_iam_role.github_actions_ecr_push.arn
}
