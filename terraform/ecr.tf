resource "aws_ecr_repository" "versioned_app" {
  name                 = "versioned-app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = var.tags
}

output "ecr_repository_arn" {
  value = aws_ecr_repository.versioned_app.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.versioned_app.repository_url
}

