# ---------------------------------------------------------------------------
# Gateway service role (outbound auth to the Web Search backend)
#
# The Gateway authenticates to the AWS-managed Web Search connector with this
# role, so there are no search API keys or secrets to store anywhere.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "gateway_assume" {
  statement {
    sid     = "AllowAgentCoreAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    # Scoped to account + Region + resource type. We deliberately do NOT narrow
    # to the exact Gateway ARN: the Gateway depends on this role via role_arn,
    # so referencing the Gateway ARN here would create a dependency cycle.
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock-agentcore:${var.region}:${local.account_id}:gateway/*"]
    }
  }
}

resource "aws_iam_role" "gateway_service" {
  name               = "${var.name_prefix}-gateway-role"
  description        = "Outbound auth for the AgentCore Web Search Gateway"
  assume_role_policy = data.aws_iam_policy_document.gateway_assume.json
}

data "aws_iam_policy_document" "gateway_service" {
  statement {
    sid       = "InvokeGateway"
    effect    = "Allow"
    actions   = ["bedrock-agentcore:InvokeGateway"]
    resources = [aws_bedrockagentcore_gateway.web_search.gateway_arn]
  }

  statement {
    sid       = "InvokeWebSearch"
    effect    = "Allow"
    actions   = ["bedrock-agentcore:InvokeWebSearch"]
    resources = [local.web_search_tool_arn]
  }
}

resource "aws_iam_role_policy" "gateway_service" {
  name   = "${var.name_prefix}-gateway-policy"
  role   = aws_iam_role.gateway_service.id
  policy = data.aws_iam_policy_document.gateway_service.json
}

# ---------------------------------------------------------------------------
# The Gateway — an MCP endpoint with IAM (SigV4) inbound auth
#
# AWS_IAM inbound is what lets the Gateway VPC endpoint policy in network.tf
# scope the Principal to exactly the runtime role. With CUSTOM_JWT the endpoint
# policy Principal would have to be "*".
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_gateway" "web_search" {
  name        = "${var.name_prefix}-gateway"
  description = "Managed web search for the TechEventsFinder agent (private ingress)"
  role_arn    = aws_iam_role.gateway_service.arn

  authorizer_type = "AWS_IAM"
  protocol_type   = "MCP"

  protocol_configuration {
    mcp {
      supported_versions = var.mcp_supported_versions

      # Semantic tool search: context-based tool discovery that lifts the
      # tools/list limits. Can only be set at creation — changing it forces a
      # new Gateway. See the enable_semantic_search variable for the cost note.
      search_type = var.enable_semantic_search ? "SEMANTIC" : null

      # Stream tool responses back incrementally over the MCP transport.
      streaming_configuration {
        enable_response_streaming = var.enable_response_streaming
      }
    }
  }
}

# ---------------------------------------------------------------------------
# The Web Search target — the AWS-managed connector
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_gateway_target" "web_search" {
  name               = var.target_name
  description        = "AWS-managed Web Search connector"
  gateway_identifier = aws_bedrockagentcore_gateway.web_search.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      connector {
        source {
          connector_id = "web-search"
          version      = var.connector_version
        }

        configuration {
          name             = "WebSearch"
          parameter_values = local.parameter_values
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.domain_include) == 0 || var.connector_version == "1.2.0"
      error_message = "domain_include (the target-level allowlist) requires connector_version 1.2.0. Either set connector_version = \"1.2.0\" or use domain_exclude instead."
    }
  }

  depends_on = [aws_iam_role_policy.gateway_service]
}
