output "ecr_repository_arn" {
  value = aws_ecr_repository.versioned_app.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.versioned_app.repository_url
}

output "github_actions_ecr_push_role_arn" {
  description = "Role ARN assumed by GitHub Actions (versioned-app) to push images to ECR"
  value       = aws_iam_role.github_actions_ecr_push.arn
}
