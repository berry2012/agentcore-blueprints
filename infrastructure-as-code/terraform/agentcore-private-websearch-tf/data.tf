data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Short-lived token the docker provider uses to push the agent image to ECR.
data "aws_ecr_authorization_token" "this" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix

  # The Web Search connector is an AWS-owned resource: note the literal `aws`
  # where an account ID would normally go.
  web_search_tool_arn = "arn:${local.partition}:bedrock-agentcore:${var.region}:aws:tool/web-search.v1"

  # Target-level domain governance. Emit only the keys that are set, so an
  # unfiltered run sends `{}` rather than empty arrays.
  domain_filter = merge(
    length(var.domain_include) > 0 ? { include = var.domain_include } : {},
    length(var.domain_exclude) > 0 ? { exclude = var.domain_exclude } : {},
  )
  parameter_values = length(local.domain_filter) > 0 ? jsonencode({ domainFilter = local.domain_filter }) : jsonencode({})

  # What the agent discovers over MCP: target name + "___" + tool name.
  tool_name = "${var.target_name}___WebSearch"

  # Private ECR registry host for this account/Region.
  ecr_registry = "${local.account_id}.dkr.ecr.${var.region}.${local.dns_suffix}"

  # ECR stores image layers in a Regional S3 bucket. The S3 *gateway* endpoint
  # policy is scoped to exactly this bucket so the runtime can pull its image at
  # startup without any broader S3 reach. (Runtimes created after the May 2026
  # rollout have no service-managed S3 gateway — the VPC must provide it.)
  ecr_layer_bucket_arn = "arn:${local.partition}:s3:::prod-${var.region}-starport-layer-bucket/*"
}
