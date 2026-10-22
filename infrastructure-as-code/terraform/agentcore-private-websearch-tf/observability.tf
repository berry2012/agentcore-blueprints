# ---------------------------------------------------------------------------
# AgentCore observability: CloudWatch Logs + traces
#
# For BOTH the Gateway and the Runtime, log and trace delivery must be wired
# explicitly with the CloudWatch Logs "vended log delivery" API:
#
#   delivery source (the resource) --> delivery --> delivery destination
#
# Although AgentCore creates a service log group for a Runtime, that group stays
# empty and the console/GenAI-Observability panes report "not enabled" until a
# delivery is configured — exactly like the Gateway. We wire both here.
#
# Two log types are delivered per resource:
#   APPLICATION_LOGS - the resource's structured logs
#   TRACES           - OpenTelemetry spans (needs Transaction Search; see below)
# ---------------------------------------------------------------------------

# Application-logs destination: a CloudWatch log group. The name follows the
# console's convention for gateway vended logs so it is where operators expect.
resource "aws_cloudwatch_log_group" "gateway_logs" {
  name              = "/aws/vendedlogs/bedrock-agentcore/gateway/APPLICATION_LOGS/${aws_bedrockagentcore_gateway.web_search.gateway_id}"
  retention_in_days = var.log_retention_days
}

# --- Application logs delivery --------------------------------------------

resource "aws_cloudwatch_log_delivery_source" "gateway_logs" {
  name         = "${var.name_prefix}-gw-logs-source"
  log_type     = "APPLICATION_LOGS"
  resource_arn = aws_bedrockagentcore_gateway.web_search.gateway_arn
}

resource "aws_cloudwatch_log_delivery_destination" "gateway_logs" {
  name                      = "${var.name_prefix}-gw-logs-dest"
  delivery_destination_type = "CWL"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.gateway_logs.arn
  }
}

resource "aws_cloudwatch_log_delivery" "gateway_logs" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.gateway_logs.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.gateway_logs.arn
}

# --- Traces delivery (spans) ----------------------------------------------
#
# Spans go to X-Ray / CloudWatch Transaction Search, not to a log group. This
# delivery only works once CloudWatch Transaction Search is enabled for the
# account+Region (an account-wide, one-time setting). We gate it behind a
# variable rather than flipping that account-wide switch from this sample:
#
#   aws cloudwatch console: Application Signals (APM) > Transaction search > Enable
#   or:
#   aws xray update-trace-segment-destination --destination CloudWatchLogs --region <region>
#
# When Transaction Search is on, the CloudWatch Logs delivery service also
# auto-manages the X-Ray resource policy that lets delivery.logs.amazonaws.com
# call xray:PutTraceSegments for gateway/* sources — so there is nothing extra
# to create here.

resource "aws_cloudwatch_log_delivery_source" "gateway_traces" {
  count = var.enable_gateway_tracing ? 1 : 0

  name         = "${var.name_prefix}-gw-traces-source"
  log_type     = "TRACES"
  resource_arn = aws_bedrockagentcore_gateway.web_search.gateway_arn
}

resource "aws_cloudwatch_log_delivery_destination" "gateway_traces" {
  count = var.enable_gateway_tracing ? 1 : 0

  name                      = "${var.name_prefix}-gw-traces-dest"
  delivery_destination_type = "XRAY"
}

resource "aws_cloudwatch_log_delivery" "gateway_traces" {
  count = var.enable_gateway_tracing ? 1 : 0

  delivery_source_name     = aws_cloudwatch_log_delivery_source.gateway_traces[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.gateway_traces[0].arn
}

# ===========================================================================
# Runtime observability
#
# The Runtime needs the same explicit vended-log delivery as the Gateway. The
# auto-created /aws/bedrock-agentcore/runtimes/<id>-DEFAULT group does NOT count
# as "logging enabled" on its own — a delivery to a vended-logs group is what
# the console and GenAI Observability read. Spans emitted by the ADOT-wrapped
# agent (see agent/Dockerfile) are delivered via the TRACES source below.
# ===========================================================================

resource "aws_cloudwatch_log_group" "runtime_logs" {
  name              = "/aws/vendedlogs/bedrock-agentcore/runtime/APPLICATION_LOGS/${aws_bedrockagentcore_agent_runtime.techevents.agent_runtime_id}"
  retention_in_days = var.log_retention_days
}

# --- Runtime application-logs delivery ------------------------------------

resource "aws_cloudwatch_log_delivery_source" "runtime_logs" {
  name         = "${var.name_prefix}-rt-logs-source"
  log_type     = "APPLICATION_LOGS"
  resource_arn = aws_bedrockagentcore_agent_runtime.techevents.agent_runtime_arn
}

resource "aws_cloudwatch_log_delivery_destination" "runtime_logs" {
  name                      = "${var.name_prefix}-rt-logs-dest"
  delivery_destination_type = "CWL"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.runtime_logs.arn
  }
}

resource "aws_cloudwatch_log_delivery" "runtime_logs" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.runtime_logs.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.runtime_logs.arn
}

# --- Runtime traces delivery (spans) --------------------------------------
#
# Same Transaction Search prerequisite as the Gateway traces above. The agent
# image is ADOT-instrumented (opentelemetry-instrument in the Dockerfile), so
# with this delivery in place its spans reach X-Ray / Transaction Search and
# the GenAI Observability dashboard.

resource "aws_cloudwatch_log_delivery_source" "runtime_traces" {
  count = var.enable_runtime_tracing ? 1 : 0

  name         = "${var.name_prefix}-rt-traces-source"
  log_type     = "TRACES"
  resource_arn = aws_bedrockagentcore_agent_runtime.techevents.agent_runtime_arn
}

resource "aws_cloudwatch_log_delivery_destination" "runtime_traces" {
  count = var.enable_runtime_tracing ? 1 : 0

  name                      = "${var.name_prefix}-rt-traces-dest"
  delivery_destination_type = "XRAY"
}

resource "aws_cloudwatch_log_delivery" "runtime_traces" {
  count = var.enable_runtime_tracing ? 1 : 0

  delivery_source_name     = aws_cloudwatch_log_delivery_source.runtime_traces[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.runtime_traces[0].arn
}
