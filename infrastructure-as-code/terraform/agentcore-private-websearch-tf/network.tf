# ---------------------------------------------------------------------------
# Private VPC for the agent runtime
#
# The whole point of this sample: the runtime's elastic network interfaces live
# in private subnets with NO internet gateway and NO NAT gateway. Every AWS API
# the agent and the platform need is reached through an interface or gateway VPC
# endpoint created below. Nothing in this VPC has a public IP or an internet
# route.
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Map supported AZ IDs -> AZ names for this account. AgentCore Runtime VPC
  # mode is not available in every AZ, and AZ names map to different AZ IDs per
  # account, so we select by stable AZ ID. If availability_zone_ids is empty,
  # fall back to the Region's natural AZ order.
  az_id_to_name = zipmap(
    data.aws_availability_zones.available.zone_ids,
    data.aws_availability_zones.available.names,
  )

  supported_az_names = length(var.availability_zone_ids) > 0 ? [
    for id in var.availability_zone_ids : local.az_id_to_name[id]
    if contains(keys(local.az_id_to_name), id)
  ] : data.aws_availability_zones.available.names

  # One AZ per subnet, cycling through the supported AZ names.
  subnet_azs = [
    for i in range(length(var.private_subnet_cidrs)) :
    local.supported_az_names[i % length(local.supported_az_names)]
  ]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for private DNS on the interface endpoints

  tags = { Name = "${var.name_prefix}-vpc" }

  lifecycle {
    precondition {
      condition     = length(local.supported_az_names) >= 1
      error_message = "None of availability_zone_ids resolved to an AZ in this account/Region. Check the IDs against: aws ec2 describe-availability-zones."
    }
  }
}

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.subnet_azs[count.index]

  # Private by construction: never auto-assign public IPs.
  map_public_ip_on_launch = false

  tags = { Name = "${var.name_prefix}-private-${count.index + 1}" }
}

# A single route table with no 0.0.0.0/0 route. Local routes only — there is
# nowhere for internet-bound traffic to go, which is the guarantee we want.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

# The runtime's ENIs. No ingress at all — AgentCore reaches the agent over its
# managed data path, not by connecting to a port in this SG. Egress is limited
# to HTTPS, and only to the VPC endpoint SG, so the agent can talk to AWS
# services through PrivateLink and nowhere else.
resource "aws_security_group" "runtime" {
  name        = "${var.name_prefix}-runtime-sg"
  description = "AgentCore runtime ENIs: egress to VPC endpoints over 443 only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-runtime-sg" }
}

resource "aws_security_group_rule" "runtime_egress_to_endpoints" {
  type                     = "egress"
  description              = "HTTPS to interface VPC endpoints"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.runtime.id
  source_security_group_id = aws_security_group.endpoints.id
}

# The S3 *gateway* endpoint is reached via the route table and the S3 prefix
# list, NOT through an ENI in the endpoint SG — so the egress rule above does
# not cover it. Without this rule the runtime can reach the interface endpoints
# but its ECR image-layer pulls from S3 time out ("Failed to pull image ...
# dial tcp <s3-ip>:443: i/o timeout"). Allow 443 to the managed S3 prefix list.
resource "aws_security_group_rule" "runtime_egress_to_s3" {
  type              = "egress"
  description       = "HTTPS to S3 via the gateway endpoint prefix list (ECR image layers)"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.runtime.id
  prefix_list_ids   = [aws_vpc_endpoint.s3.prefix_list_id]
}

# The interface VPC endpoints. Accept HTTPS only from the runtime SG — no other
# source, and certainly not 0.0.0.0/0.
resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-vpce-sg"
  description = "Interface VPC endpoints: accept 443 from the runtime SG only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-vpce-sg" }
}

resource "aws_security_group_rule" "endpoints_ingress_from_runtime" {
  type                     = "ingress"
  description              = "HTTPS from the runtime ENIs"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.endpoints.id
  source_security_group_id = aws_security_group.runtime.id
}

# ---------------------------------------------------------------------------
# S3 gateway endpoint — for ECR image-layer pulls at runtime startup
#
# Container image layers are stored in a Regional S3 bucket. Without this
# gateway endpoint the pull has no route (there is no NAT), so the runtime would
# never start. The policy is scoped to just the ECR layer bucket.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "s3_endpoint" {
  statement {
    sid       = "AllowECRLayerAccess"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.ecr_layer_bucket_arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  policy            = data.aws_iam_policy_document.s3_endpoint.json

  tags = { Name = "${var.name_prefix}-s3-gw" }
}

# ---------------------------------------------------------------------------
# Interface endpoints
#
# One per AWS service the runtime or the platform must reach. Private DNS is on,
# so SDK calls to the default regional hostnames resolve to these ENIs. The
# Gateway endpoint is the one that lets the agent reach the Web Search Gateway
# without leaving the VPC.
# ---------------------------------------------------------------------------

locals {
  # Data-plane / infra endpoints with the default (full-access) policy. These
  # carry only image pulls and log puts from the runtime; the sensitive access
  # control lives on the Gateway and bedrock endpoints below.
  interface_endpoints = {
    ecr_api = "com.amazonaws.${var.region}.ecr.api"
    ecr_dkr = "com.amazonaws.${var.region}.ecr.dkr"
    logs    = "com.amazonaws.${var.region}.logs"
    # AgentCore data plane (workload identity / access tokens the SDK fetches
    # at runtime). Harmless to include and required by some SDK paths.
    agentcore = "com.amazonaws.${var.region}.bedrock-agentcore"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.this.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-${replace(each.key, "_", "-")}-vpce" }
}

# Bedrock runtime endpoint — the model the agent reasons with. Scoped to just
# InvokeModel actions so this endpoint cannot be used for anything else.
data "aws_iam_policy_document" "bedrock_endpoint" {
  statement {
    sid    = "AllowInvokeModel"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.runtime_execution.arn]
    }
  }
}

resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  policy              = data.aws_iam_policy_document.bedrock_endpoint.json

  # The policy names the runtime role as Principal; wait for it to propagate.
  depends_on = [time_sleep.wait_for_runtime_role]

  tags = { Name = "${var.name_prefix}-bedrock-runtime-vpce" }
}

# ---------------------------------------------------------------------------
# AgentCore GATEWAY endpoint — the private ingress to the Web Search Gateway
#
# This is the endpoint the user's requirement is about. Because the Gateway
# uses AWS_IAM (SigV4) inbound auth, the endpoint policy can scope BOTH the
# Principal (only the runtime's execution role) AND the Resource (only this
# Gateway). With JWT inbound, the service requires Principal = "*".
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "gateway_endpoint" {
  statement {
    sid       = "AllowRuntimeInvokeThisGateway"
    effect    = "Allow"
    actions   = ["bedrock-agentcore:InvokeGateway"]
    resources = [aws_bedrockagentcore_gateway.web_search.gateway_arn]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.runtime_execution.arn]
    }
  }
}

resource "aws_vpc_endpoint" "gateway" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.bedrock-agentcore.gateway"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  policy              = data.aws_iam_policy_document.gateway_endpoint.json

  # The policy names the runtime role as Principal; wait for it to propagate.
  depends_on = [time_sleep.wait_for_runtime_role]

  tags = { Name = "${var.name_prefix}-gateway-vpce" }
}
