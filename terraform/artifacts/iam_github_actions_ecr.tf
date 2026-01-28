#############################
# GitHub Actions OIDC Provider
#############################

data "tls_certificate" "github_actions" {
  url =  "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url =  "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]

  thumbprint_list = [
    data.tls_certificate.github_actions.certificates[0].sha1_fingerprint,
  ]
}

#############################
# Inputs (minimal)
#############################

variable "github_org" {
  type        = string
  description = "GitHub org/user that owns the repo"
  default     = "dgeoghegan"
}

variable "github_repo_versioned_app" {
  type        = string
  description = "Repo name for the app, e.g. versioned-app"
  default     = "versioned-app"
}

variable "github_branch" {
  type        = string
  description = "Branch allowed to assume role, e.g. main"
  default     = "main"
}

variable "ecr_repository_name" {
  description = "ECR repository for publishing containers"
  type        = string
  default     = "versioned-app"
}

data  "aws_region" "current" {}

locals {
  ecr_repo_arn  = "arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repository_name}"
}


#############################
# Trust policy (repo + branch restricted)
#############################

data "aws_iam_policy_document" "gha_assume_role" {
  statement {
    effect    = "Allow"
    actions   = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test      = "StringEquals"
      variable  = "token.actions.githubusercontent.com:aud"
      values    = ["sts.amazonaws.com"]
    }

    # Restrict to exact repo + branch ref
    condition {
      test      = "StringLike"
      variable  = "token.actions.githubusercontent.com:sub"
      values    = [
        "repo:${var.github_org}/${var.github_repo_versioned_app}:ref:refs/heads/${var.github_branch}",
        "repo:${var.github_org}/${var.github_repo_versioned_app}:ref:refs/tags/v*"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_ecr_push" {
  name                = "github-actions-ecr-push"
  assume_role_policy  = data.aws_iam_policy_document.gha_assume_role.json
}

#############################
# Least-privilege permissions for ECR push
#############################

data "aws_iam_policy_document" "ecr_push" {
  # Needed for auth token (must be "*")
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push/pull actions limited to a single repo
  statement {
    effect    = "Allow"
    actions   = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [local.ecr_repo_arn]
  }
}

resource "aws_iam_policy" "github_actions_ecr_push" {
  name    = "github-actions-ecr-push-policy"
  policy  = data.aws_iam_policy_document.ecr_push.json
}

resource "aws_iam_role_policy_attachment" "attach_ecr_push" {
  role        = aws_iam_role.github_actions_ecr_push.name
  policy_arn  = aws_iam_policy.github_actions_ecr_push.arn
}
