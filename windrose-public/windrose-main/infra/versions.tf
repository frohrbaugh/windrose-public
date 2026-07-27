terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # Local state is fine for a single-maintainer personal project.
  # The state file lives in infra/terraform.tfstate (gitignored). Back it up
  # if you care about it — losing it means Terraform forgets what it created.
}
