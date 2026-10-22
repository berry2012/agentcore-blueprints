# ---------------------------------------------------------------------------
# Private ECR repository for the agent image
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "agent" {
  name                 = "${var.name_prefix}-agent"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # a demo repo; allow destroy to remove images too

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ---------------------------------------------------------------------------
# Build and push the agent's ARM64 image
#
# AgentCore Runtime only starts linux/arm64 (Graviton) images. The content hash
# over the agent source + Dockerfile becomes the image tag, so any change to the
# agent re-tags, re-pushes, and forces a new runtime version — and an unchanged
# agent is a no-op on re-apply.
# ---------------------------------------------------------------------------

locals {
  agent_dir = "${path.module}/agent"

  agent_source_hash = substr(sha256(join("", [
    filesha256("${local.agent_dir}/agent.py"),
    filesha256("${local.agent_dir}/requirements.txt"),
    filesha256("${local.agent_dir}/Dockerfile"),
  ])), 0, 16)

  agent_image_tag = "v-${local.agent_source_hash}"
  agent_image_uri = "${aws_ecr_repository.agent.repository_url}:${local.agent_image_tag}"
}

resource "docker_image" "agent" {
  name = local.agent_image_uri

  build {
    context    = local.agent_dir
    dockerfile = "Dockerfile"
    platform   = "linux/arm64"
  }

  # Rebuild when any source file changes.
  triggers = {
    source_hash = local.agent_source_hash
  }
}

resource "docker_registry_image" "agent" {
  name          = docker_image.agent.name
  keep_remotely = true # don't delete the pushed image when Terraform forgets it

  triggers = {
    source_hash = local.agent_source_hash
  }
}

# ---------------------------------------------------------------------------
# Runtime execution role (the identity the agent runs as)
#
# AgentCore assumes this role to run the agent. It carries exactly what the
# agent needs: pull the image, write logs, reason with Bedrock, and — the point
# of this sample — InvokeGateway on the Web Search Gateway so the agent can call
# the web-search tool over MCP.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "runtime_assume" {
  statement {
    sid     = "AssumeRolePolicy"
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

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock-agentcore:${var.region}:${local.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "runtime_execution" {
  name               = "${var.name_prefix}-runtime-role"
  description        = "Execution role for the TechEventsFinder AgentCore runtime"
  assume_role_policy = data.aws_iam_policy_document.runtime_assume.json
}

data "aws_iam_policy_document" "runtime_execution" {
  # Pull the agent image.
  statement {
    sid       = "ECRImageAccess"
    effect    = "Allow"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.agent.arn]
  }

  statement {
    sid       = "ECRTokenAccess"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # CloudWatch Logs for the runtime.
  statement {
    sid       = "LogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogStreams", "logs:CreateLogGroup"]
    resources = ["arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*"]
  }

  statement {
    sid       = "LogResourcePolicy"
    effect    = "Allow"
    actions   = ["logs:PutResourcePolicy"]
    resources = ["arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/${var.agent_runtime_name}-*"]
  }

  statement {
    sid       = "LogDescribeGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:*"]
  }

  statement {
    sid       = "LogStreams"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"]
  }

  # Observability (optional but part of the documented execution role).
  statement {
    sid       = "XRay"
    effect    = "Allow"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  }

  statement {
    sid       = "CloudWatchMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["bedrock-agentcore"]
    }
  }

  # Workload identity tokens the AgentCore SDK fetches at runtime.
  statement {
    sid     = "GetAgentAccessToken"
    effect  = "Allow"
    actions = ["bedrock-agentcore:GetWorkloadAccessToken", "bedrock-agentcore:GetWorkloadAccessTokenForJWT", "bedrock-agentcore:GetWorkloadAccessTokenForUserId"]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${var.region}:${local.account_id}:workload-identity-directory/default",
      "arn:${local.partition}:bedrock-agentcore:${var.region}:${local.account_id}:workload-identity-directory/default/workload-identity/${var.agent_runtime_name}-*",
    ]
  }

  # Reason with Bedrock. Reaches the model through the bedrock-runtime VPC
  # endpoint in network.tf.
  statement {
    sid       = "BedrockModelInvocation"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["arn:${local.partition}:bedrock:*::foundation-model/*", "arn:${local.partition}:bedrock:${var.region}:${local.account_id}:*"]
  }

  # The point of the sample: call the Web Search Gateway over MCP.
  statement {
    sid       = "InvokeWebSearchGateway"
    effect    = "Allow"
    actions   = ["bedrock-agentcore:InvokeGateway"]
    resources = [aws_bedrockagentcore_gateway.web_search.gateway_arn]
  }
}

resource "aws_iam_role_policy" "runtime_execution" {
  name   = "${var.name_prefix}-runtime-policy"
  role   = aws_iam_role.runtime_execution.id
  policy = data.aws_iam_policy_document.runtime_execution.json
}

# VPC endpoint policies in network.tf reference the runtime role as a Principal.
# The EC2 CreateVpcEndpoint policy validator rejects a role ARN it cannot yet
# resolve, so give IAM a few seconds to propagate the new role before those
# endpoints are created. Without this the first apply can fail with
# "InvalidPolicyDocument: UnknownError" on a cold role.
resource "time_sleep" "wait_for_runtime_role" {
  create_duration = "15s"
  depends_on      = [aws_iam_role.runtime_execution]
}

# ---------------------------------------------------------------------------
# The AgentCore Runtime — in VPC mode
#
# network_mode = "VPC" places the agent's ENIs in the private subnets. With no
# NAT or internet gateway, the agent can reach AWS services only through the VPC
# endpoints in network.tf: Bedrock for the model, and the Gateway endpoint for
# the Web Search tool.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_agent_runtime" "techevents" {
  agent_runtime_name = var.agent_runtime_name
  description        = "TechEventsFinder: a private agent that finds tech events via the Web Search Gateway"
  role_arn           = aws_iam_role.runtime_execution.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.agent.repository_url}@${docker_registry_image.agent.sha256_digest}"
    }
  }

  network_configuration {
    network_mode = "VPC"

    network_mode_config {
      security_groups = [aws_security_group.runtime.id]
      subnets         = aws_subnet.private[*].id
    }
  }

  protocol_configuration {
    server_protocol = "HTTP"
  }

  environment_variables = {
    GATEWAY_MCP_URL         = local.mcp_endpoint
    GATEWAY_TOOL_NAME       = local.tool_name
    BEDROCK_MODEL_ID        = var.bedrock_model_id
    AWS_REGION              = var.region
    MCP_PROTOCOL_VERSION    = var.mcp_supported_versions[0]
    CONNECT_TIMEOUT_SECONDS = tostring(var.connect_timeout_seconds)
  }

  # The execution role's InvokeGateway permission, the Gateway target, and the
  # pushed image must all exist before the runtime is created.
  depends_on = [
    aws_iam_role_policy.runtime_execution,
    aws_bedrockagentcore_gateway_target.web_search,
    aws_vpc_endpoint.gateway,
    aws_vpc_endpoint.bedrock_runtime,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3,
    docker_registry_image.agent,
  ]
}

# Note: AgentCore automatically creates a "DEFAULT" endpoint on CreateAgentRuntime
# that always points at the latest version, so no endpoint resource is needed
# here. invoke-agent.py targets that DEFAULT qualifier. Add a named
# aws_bedrockagentcore_agent_runtime_endpoint only if you want a pinned
# prod/staging alias.
