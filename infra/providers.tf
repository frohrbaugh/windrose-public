provider "aws" {
  region = var.aws_region
  # null (not "") so an unset profile falls through to the default credential chain.
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project   = "windrose"
      ManagedBy = "terraform"
    }
  }
}
