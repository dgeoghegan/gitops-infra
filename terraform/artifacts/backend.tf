terraform {
  backend "s3" {
    bucket         = "dgeoghegan-tfstate-us-east-1"
    key            = "gitops-infra/artifacts/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

