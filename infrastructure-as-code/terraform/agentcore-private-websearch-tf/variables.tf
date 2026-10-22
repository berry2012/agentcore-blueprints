variable "region" {
  description = "AWS Region to deploy into. Must be a Region where the AgentCore Web Search Tool connector AND AgentCore Runtime VPC mode are available."
  type        = string
  default     = "us-east-1"

  validation {
    # Source: AgentCore devguide, "Web Search Tool" > Availability. The Runtime
    # and PrivateLink endpoints are available in a superset of these, so the
    # connector list is the binding constraint.
    condition = contains([
      "us-east-1",
      "us-east-2",
      "us-west-2",
      "eu-west-1",
      "ap-southeast-2",
      "ap-northeast-1",
      "us-gov-west-1",
    ], var.region)
    error_message = "Web Search Tool is only available in us-east-1, us-east-2, us-west-2, eu-west-1, ap-southeast-2, ap-northeast-1, us-gov-west-1."
  }
}

variable "name_prefix" {
  description = "Prefix applied to the names of created resources."
  type        = string
  default     = "techevents"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{1,24}$", var.name_prefix))
    error_message = "name_prefix must be 1-24 characters of letters, digits, or hyphens."
  }
}

variable "agent_runtime_name" {
  description = <<-EOT
    Name of the AgentCore Runtime agent. The execution role and runtime log
    groups are scoped to this name, so it must be decided before apply. Only
    letters and digits are allowed by the service (no hyphens).
  EOT
  type        = string
  default     = "TechEventsFinder"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9]{0,47}$", var.agent_runtime_name))
    error_message = "agent_runtime_name must start with a letter and contain only letters and digits (1-48 chars)."
  }
}

variable "target_name" {
  description = <<-EOT
    Name of the gateway target. The Gateway exposes a target's tools as
    `<target_name>___<ToolName>`, so this value determines the tool name the
    agent discovers: the default yields `web-search___WebSearch`.
  EOT
  type        = string
  default     = "web-search"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{1,48}$", var.target_name))
    error_message = "target_name must be 1-48 characters of letters, digits, or hyphens."
  }
}

variable "connector_version" {
  description = <<-EOT
    Version of the AWS-managed `web-search` connector to pin. Version 1.2.0 adds
    the target-level domain *include* list plus per-request domain and
    published-date filters. 1.1.0 supports only the target-level exclude list.
  EOT
  type        = string
  default     = "1.2.0"

  validation {
    condition     = contains(["1.1.0", "1.2.0"], var.connector_version)
    error_message = "connector_version must be \"1.1.0\" or \"1.2.0\"."
  }
}

variable "bedrock_model_id" {
  description = <<-EOT
    Bedrock model (or inference profile) ID the TechEventsFinder agent reasons
    with. Must be enabled in this account/Region and reachable over the
    bedrock-runtime interface endpoint created in network.tf. The default is a
    cross-Region inference profile for Claude; override to match what you have
    entitlement for.
  EOT
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"

  validation {
    condition     = length(var.bedrock_model_id) > 0
    error_message = "bedrock_model_id must not be empty."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC created for the private agent runtime."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "private_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for the private subnets the runtime's ENIs and all VPC endpoints
    live in. Provide at least two in different AZs for resilience. These subnets
    have NO route to an internet or NAT gateway — every AWS call egresses
    through a VPC endpoint.
  EOT
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "Provide at least two private subnet CIDRs (one per AZ) for resilience."
  }
}

variable "availability_zone_ids" {
  description = <<-EOT
    AZ *IDs* (e.g. use1-az1) the private subnets may use. AgentCore Runtime VPC
    mode is not supported in every AZ of a Region, and an account's AZ names map
    to different AZ IDs, so selection is by stable AZ ID rather than name. Leave
    empty to let Terraform use the first AZs returned for the Region (works in
    Regions where all AZs are supported); set it to the Runtime-supported IDs
    when a CreateAgentRuntime call reports "unsupported availability zones".

    For us-east-1 the Runtime-supported IDs are use1-az1, use1-az2, use1-az4,
    use1-az6 is NOT supported, so the default pins the three supported ones.
  EOT
  type        = list(string)
  default     = ["use1-az1", "use1-az2", "use1-az4"]
}

variable "connect_timeout_seconds" {
  description = <<-EOT
    How long the agent waits for the Gateway MCP endpoint before giving up.
    Kept short so a misconfigured endpoint surfaces quickly rather than hanging
    the whole invocation.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.connect_timeout_seconds >= 5 && var.connect_timeout_seconds <= 120
    error_message = "connect_timeout_seconds must be between 5 and 120."
  }
}

variable "domain_include" {
  description = <<-EOT
    Target-level domain allowlist. When non-empty, Web Search returns results
    ONLY from these domains (a root domain also matches its subdomains). Hidden
    from the agent and applied to every request, so no prompt injection can
    widen it. Requires connector_version 1.2.0.

    Empty by default so the default run is unfiltered.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.domain_include) <= 100
    error_message = "domain_include accepts at most 100 domains."
  }
}

variable "domain_exclude" {
  description = <<-EOT
    Target-level domain denylist. Results from these domains are always dropped.
    Hidden from the agent and applied to every request. Works on both connector
    1.1.0 and 1.2.0.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.domain_exclude) <= 100
    error_message = "domain_exclude accepts at most 100 domains."
  }
}

variable "mcp_supported_versions" {
  description = <<-EOT
    MCP protocol versions the Gateway will accept. Defaults to the latest MCP
    revision, 2025-11-25 (the November 2025 spec release). The agent sends this
    same version in its MCP-Protocol-Version header.
  EOT
  type        = list(string)
  default     = ["2025-11-25"]

  validation {
    condition     = length(var.mcp_supported_versions) > 0
    error_message = "mcp_supported_versions must contain at least one version."
  }
}

variable "enable_semantic_search" {
  description = <<-EOT
    Enable the Gateway's SEMANTIC tool search (search_type = SEMANTIC). It
    improves tool discovery by matching tools to the request context and lifts
    the usual tools/list limits — useful as you add more targets. It adds
    per-call semantic-search cost and per-tool monthly indexing cost, so it is a
    variable rather than always-on. The built-in `x_amz_bedrock_agentcore_search`
    tool becomes available for context-based discovery.
  EOT
  type        = bool
  default     = true
}

variable "enable_response_streaming" {
  description = <<-EOT
    Enable MCP response streaming on the Gateway
    (streaming_configuration.enable_response_streaming). Lets the Gateway stream
    tool responses back incrementally over the MCP transport.
  EOT
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the Gateway application-logs CloudWatch log group."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653, 0], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch Logs retention value (e.g. 1, 7, 30, 90, 365) or 0 for never expire."
  }
}

variable "enable_gateway_tracing" {
  description = <<-EOT
    Deliver Gateway OpenTelemetry spans (TRACES) to CloudWatch/X-Ray. This
    REQUIRES CloudWatch Transaction Search to be enabled for the account+Region
    (an account-wide, one-time setting this sample does not flip for you):

      aws xray update-trace-segment-destination --destination CloudWatchLogs

    Application-logs delivery does not depend on this and is always configured.
    Set to false if Transaction Search is not enabled, to avoid a non-delivering
    traces delivery.
  EOT
  type        = bool
  default     = true
}

variable "enable_runtime_tracing" {
  description = <<-EOT
    Deliver the Runtime's OpenTelemetry spans (TRACES) to CloudWatch/X-Ray. Same
    account-level CloudWatch Transaction Search prerequisite as
    enable_gateway_tracing. The agent image is ADOT-instrumented, so with this
    delivery the agent's spans reach the GenAI Observability dashboard.
    Runtime application-logs delivery is always configured regardless.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources that support tagging."
  type        = map(string)
  default = {
    Project   = "agentcore-private-websearch"
    ManagedBy = "terraform"
  }
}
