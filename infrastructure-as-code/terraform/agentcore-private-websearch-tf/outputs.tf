locals {
  gateway_url_trimmed = trimsuffix(aws_bedrockagentcore_gateway.web_search.gateway_url, "/")

  # Normalize to the MCP endpoint. The control plane's gatewayUrl usually ends
  # in /mcp, but guard rather than assume so the agent never hits a 404.
  mcp_endpoint = endswith(local.gateway_url_trimmed, "/mcp") ? local.gateway_url_trimmed : "${local.gateway_url_trimmed}/mcp"
}

output "agent_runtime_arn" {
  description = "ARN of the TechEventsFinder runtime. Callers need bedrock-agentcore:InvokeAgentRuntime on this."
  value       = aws_bedrockagentcore_agent_runtime.techevents.agent_runtime_arn
}

output "agent_runtime_id" {
  description = "Runtime identifier."
  value       = aws_bedrockagentcore_agent_runtime.techevents.agent_runtime_id
}

output "runtime_execution_role_arn" {
  description = "Execution role the agent runs as (reasons with Bedrock, invokes the Gateway)."
  value       = aws_iam_role.runtime_execution.arn
}

output "gateway_id" {
  description = "Gateway identifier."
  value       = aws_bedrockagentcore_gateway.web_search.gateway_id
}

output "gateway_arn" {
  description = "Gateway ARN (what InvokeGateway and the endpoint policy are scoped to)."
  value       = aws_bedrockagentcore_gateway.web_search.gateway_arn
}

output "mcp_endpoint" {
  description = "Gateway MCP endpoint the agent POSTs tools/list and tools/call to."
  value       = local.mcp_endpoint
}

output "tool_name" {
  description = "The web-search tool name the agent discovers over MCP."
  value       = local.tool_name
}

output "gateway_vpc_endpoint_id" {
  description = "Interface VPC endpoint that gives the private runtime ingress to the Gateway."
  value       = aws_vpc_endpoint.gateway.id
}

output "vpc_id" {
  description = "The private VPC the runtime's ENIs live in (no internet or NAT gateway)."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnets hosting the runtime ENIs and all VPC endpoints."
  value       = aws_subnet.private[*].id
}

output "agent_image_uri" {
  description = "ECR image URI (tag) built and pushed for the agent."
  value       = local.agent_image_uri
}

output "gateway_log_group_name" {
  description = "CloudWatch log group receiving Gateway application logs (tool calls, params, responses, errors)."
  value       = aws_cloudwatch_log_group.gateway_logs.name
}

output "gateway_tracing_enabled" {
  description = "Whether Gateway span (TRACES) delivery to X-Ray/Transaction Search is configured."
  value       = var.enable_gateway_tracing
}

output "runtime_log_group_name" {
  description = "CloudWatch vended-logs group receiving the Runtime's application logs."
  value       = aws_cloudwatch_log_group.runtime_logs.name
}

output "runtime_tracing_enabled" {
  description = "Whether Runtime span (TRACES) delivery to X-Ray/Transaction Search is configured."
  value       = var.enable_runtime_tracing
}

output "gateway_mcp_configuration" {
  description = "MCP protocol settings in effect on the Gateway."
  value = {
    supported_versions = var.mcp_supported_versions
    semantic_search    = var.enable_semantic_search
    response_streaming = var.enable_response_streaming
  }
}

output "domain_governance" {
  description = "Target-level domain filters in effect. Hidden from the agent and applied to every request."
  value = {
    include = var.domain_include
    exclude = var.domain_exclude
    active  = length(local.domain_filter) > 0
  }
}

output "invoke_command" {
  description = "Ready-to-run command that invokes the private agent and proves the end-to-end path."
  value       = "python3 scripts/invoke-agent.py --prompt \"Find upcoming AWS and cloud tech conferences\""
}
