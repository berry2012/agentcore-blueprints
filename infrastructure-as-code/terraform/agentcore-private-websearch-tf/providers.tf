provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}

# The docker provider is used only to build the agent's ARM64 image and push it
# to the private ECR repository created in runtime.tf. It authenticates to ECR
# with a short-lived token minted by the aws_ecr_authorization_token data
# source — no long-lived Docker credentials are stored anywhere.
provider "docker" {
  registry_auth {
    address  = local.ecr_registry
    username = data.aws_ecr_authorization_token.this.user_name
    password = data.aws_ecr_authorization_token.this.password
  }
}
