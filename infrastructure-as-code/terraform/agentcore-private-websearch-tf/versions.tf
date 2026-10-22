terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Two resources this sample depends on are recent:
      #   - target_configuration.mcp.connector (web-search) — provider 6.63.0
      #   - aws_bedrockagentcore_agent_runtime network_configuration VPC mode
      # Pin to a version known to carry both.
      version = "~> 6.69"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
