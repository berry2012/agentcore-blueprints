# Private Web Search Agent (Terraform)

Deploy a simple agent — **TechEventsFinder** — to Amazon Bedrock AgentCore
Runtime **inside a VPC with no internet or NAT gateway**, and give it access to
the AWS-managed **Web Search** tool through an AgentCore Gateway reached over
**AWS PrivateLink**. Everything is provisioned in one `terraform apply`.

## Introduction

This is the fully private companion to the
[Web Search Gateway](../web-search-gateway/) sample. That sample proved the
Gateway and its managed Web Search connector with a direct MCP client and no
agent. This one adds the two pieces a production-shaped deployment needs:

- **A real agent on AgentCore Runtime**, not a test client. TechEventsFinder is
  a small [Strands](https://strandsagents.com) agent that reasons with a Bedrock
  model and calls the Gateway's web-search tool over MCP to find upcoming tech
  conferences, summits, and hackathons.
- **A fully private network path.** The runtime's elastic network interfaces
  live in private subnets with **no internet gateway and no NAT gateway**. Every
  AWS call the agent makes — to Bedrock for the model, and to the Gateway for
  the web-search tool — egresses through an interface VPC endpoint. Nothing in
  the VPC has a public IP or an internet route.

The Gateway uses `AWS_IAM` (SigV4) inbound auth, which is what makes the private
ingress tight: the Gateway interface-endpoint policy scopes **both** the
`Principal` (only the runtime's execution role) **and** the `Resource` (only
this Gateway). With OAuth/JWT inbound, the endpoint-policy `Principal` would have
to be `"*"`.

## Architecture Diagram

```
  operator / CI                         Your AWS account
  ─────────────                         ────────────────────────────────────────────────
                                        ┌──────────────────────── VPC (no IGW, no NAT) ───┐
  InvokeAgentRuntime   ┌─────────────┐  │  private subnets (2 AZs)                         │
  (SigV4) ───────────▶ │  AgentCore  │  │  ┌────────────────────┐                         │
                       │  Runtime    │──┼─▶│ TechEventsFinder    │                         │
                       │  (data      │  │  │ agent (ARM64 image) │                         │
                       │   plane)    │  │  │  ENIs, no public IP │                         │
                       └─────────────┘  │  └─────────┬──────────┘                          │
                                        │            │ 443 only, to the endpoint SG        │
                                        │   ┌────────┴──────────────────────────────────┐  │
                                        │   │ interface VPC endpoints (AWS PrivateLink)  │  │
                                        │   │  • bedrock-agentcore.gateway  ──┐          │  │
                                        │   │  • bedrock-runtime  ──┐         │          │  │
                                        │   │  • ecr.api / ecr.dkr  │         │          │  │
                                        │   │  • logs               │         │          │  │
                                        │   │  • bedrock-agentcore  │         │          │  │
                                        │   └───────────────────────┼─────────┼──────────┘  │
                                        │   S3 gateway endpoint ◀────┘ (ECR    │             │
                                        │   (image-layer pulls)               │             │
                                        └─────────────────────────────────────┼─────────────┘
                                                                               ▼
                                                               ┌───────────────────────────┐
                                                               │ AgentCore Gateway (MCP,    │
                                                               │ AWS_IAM inbound)           │
                                                               │   └─ web-search target ────┼──▶ AWS-managed
                                                               └───────────────────────────┘    Web Search
                                                                                                 (served in AWS)
```

**Reasoning path (private):** the agent calls Bedrock `InvokeModel` through the
`bedrock-runtime` interface endpoint. That endpoint's policy allows only
`InvokeModel`/`InvokeModelWithResponseStream`, and only for the runtime role.

**Tool path (private):** the agent speaks MCP to the Gateway's standard URL
(`*.gateway.bedrock-agentcore.<region>.amazonaws.com`), which resolves — via the
endpoint's private DNS — to the `bedrock-agentcore.gateway` endpoint ENIs. The
agent SigV4-signs every request with its execution-role credentials; the Gateway
then uses its own service role to reach the AWS-managed Web Search backend. No
search API keys anywhere, and the search is served inside AWS.

**Startup path:** AgentCore pulls the agent's container image at startup. Image
layers live in a Regional S3 bucket fronted by ECR, so the VPC needs the
`ecr.api`, `ecr.dkr`, and a **free S3 gateway** endpoint — there is no NAT for
that traffic to traverse. (Runtimes created after the May 2026 network-isolation
rollout have no service-managed S3 gateway, so your VPC must provide it.)

### What it deploys

| Area | Resource(s) | Purpose |
| --- | --- | --- |
| Network | `aws_vpc`, 2 × `aws_subnet` (private), one route table with no `0.0.0.0/0` route | The private VPC. No IGW, no NAT, no public IPs. |
| Network | `aws_security_group` ×2 | Runtime ENIs egress 443 to the endpoint SG **and** to the S3 prefix list (ECR image layers); endpoints accept 443 **only** from the runtime SG. No `0.0.0.0/0`. |
| PrivateLink | `aws_vpc_endpoint.s3` (gateway) | ECR image-layer pulls at startup, scoped to the ECR layer bucket. |
| PrivateLink | `aws_vpc_endpoint.interface["ecr_api"|"ecr_dkr"|"logs"|"agentcore"]` | Image pulls, log puts, data-plane tokens. |
| PrivateLink | `aws_vpc_endpoint.bedrock_runtime` | The model path. Endpoint policy allows only `InvokeModel*`, only for the runtime role. |
| PrivateLink | `aws_vpc_endpoint.gateway` | **The private ingress to the Gateway.** Endpoint policy scopes Principal (runtime role) **and** Resource (this Gateway). |
| Gateway | `aws_bedrockagentcore_gateway` + `_gateway_target` + service role | The MCP endpoint and the AWS-managed web-search connector (`AWS_IAM` inbound, SEMANTIC search, response streaming, MCP 2025-11-25). |
| Observability | log groups + `aws_cloudwatch_log_delivery_source`/`_destination`/`_delivery` for **both** Gateway and Runtime | Application-logs delivery to CloudWatch Logs and span (TRACES) delivery to X-Ray / Transaction Search, for each resource. |
| Runtime | `aws_ecr_repository`, `docker_image`, `docker_registry_image` | Builds and pushes the agent's ARM64 image, instrumented with ADOT (`opentelemetry-instrument`) for tracing. |
| Runtime | `aws_iam_role.runtime_execution` (+ policy) | What the agent runs as: pull image, write logs, emit X-Ray spans (`xray:PutTraceSegments`, `logs:PutResourcePolicy`), `InvokeModel`, and `InvokeGateway` on this Gateway. |
| Runtime | `aws_bedrockagentcore_agent_runtime` (`network_mode = "VPC"`) | The agent, with its ENIs in the private subnets. Logs land in its auto-created log group; spans go there too via ADOT. |

## Prerequisites

- **Terraform >= 1.6**.
- **AWS provider `~> 6.69`** — carries both the web-search connector block and
  `aws_bedrockagentcore_agent_runtime` VPC mode. **kreuzwerker/docker `~> 3.0`**
  for the image build.
- **Docker with `buildx`**, and the daemon running. The agent image **must** be
  `linux/arm64` (AgentCore runs on Graviton); `deploy.sh` checks for buildx. On
  an x86 host, buildx uses emulation (QEMU) to cross-build — slower but works.
- **AWS CLI** configured with credentials, and permission to create VPCs, VPC
  endpoints, IAM roles, ECR repos, AgentCore gateways and runtimes, plus
  `iam:PassRole` on the two service roles.
- **Python 3.11+** with `boto3` importable — used by the invoke/test scripts.
- **A Bedrock model you are entitled to**, reachable in this Region. The default
  is a Claude cross-Region inference profile; override `bedrock_model_id` to
  match your entitlement. Unlike the Gateway-only sample, this one *does* use a
  model — the agent reasons with it.
- A Region where the Web Search connector is available: `us-east-1`, `us-east-2`,
  `us-west-2`, `eu-west-1`, `ap-southeast-2`, `ap-northeast-1`, `us-gov-west-1`.
  Defaults to `us-east-1`.

## Usage

### Option 1: Automation script (recommended)

```bash
chmod +x deploy.sh
./deploy.sh
```

Validates your environment (including Docker/buildx), initializes, plans, applies
after you confirm, then prints the outputs and the invoke command.

> The first apply builds and pushes an ARM64 image and creates a runtime; expect
> it to take several minutes. The runtime also needs a short while to reach
> `READY` before the first invoke succeeds.

### Option 2: Manual Terraform commands

```bash
cp terraform.tfvars.example terraform.tfvars   # optional: edit values
terraform init
terraform plan
terraform apply
terraform output
```

### Invoke the private agent

```bash
python3 scripts/invoke-agent.py --prompt "Find upcoming AWS and cloud tech conferences"
```

The script reads the runtime ARN from `terraform output`, calls
`InvokeAgentRuntime`, and prints a verdict:

```text
==> 1/2  Invoking the private agent (InvokeAgentRuntime)
    runtime : arn:aws:bedrock-agentcore:us-east-1:...:runtime/TechEventsFinder-...
    ...
==> 2/2  Verdict
---------------------------------------------------------------
PASS  The private agent answered using the Web Search Gateway.
      tools: web-search___WebSearch
---------------------------------------------------------------

Agent response:
  Here are upcoming tech conferences:
  1. AWS re:Invent 2026 — Dec 2026, Las Vegas — https://reinvent.awsevents.com
  ...
```

> **Where you run this script does not affect the privacy guarantee.** It calls
> the AgentCore data-plane `InvokeAgentRuntime` API; the guarantee is about the
> *agent's* egress, which never leaves the VPC. To make the invoke call itself
> private too, add a `bedrock-agentcore` data-plane endpoint (already created
> here) and run the script from a host inside the VPC.

Run the offline self-test any time — no AWS calls, no cost:

```bash
python3 scripts/selftest.py
```

## How the agent reaches the Gateway privately

`agent/agent.py` builds a Strands `MCPClient` over the MCP streamable-HTTP
transport and attaches a small `httpx.Auth` that SigV4-signs every request with
the runtime's ambient execution-role credentials:

```python
class SigV4HTTPXAuth(httpx.Auth):
    def auth_flow(self, request):
        frozen = self._creds.get_frozen_credentials()
        signer = SigV4Auth(frozen, "bedrock-agentcore", self._region)
        aws_req = AWSRequest(method=request.method, url=str(request.url),
                             data=request.content, headers=dict(request.headers))
        signer.add_auth(aws_req)
        for k, v in aws_req.headers.items():
            request.headers[k] = v
        yield request
```

Because private DNS is enabled on the Gateway endpoint, the agent uses the
Gateway's standard URL unchanged and the traffic routes through the VPC endpoint.
The signature is checked against the endpoint policy (Principal + Resource) and
then against the runtime role's IAM policy — two independent gates on the same
SigV4 identity.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `region` | `us-east-1` | Validated against the Web Search supported-Region list. |
| `name_prefix` | `techevents` | Prefix for created resource names. |
| `agent_runtime_name` | `TechEventsFinder` | Runtime name (letters/digits only); scopes the execution role and log groups. |
| `bedrock_model_id` | Claude Sonnet CRIS profile | Model the agent reasons with. Must be entitled + reachable. |
| `vpc_cidr` | `10.20.0.0/16` | VPC CIDR. |
| `private_subnet_cidrs` | two /24s | Private subnets (≥ 2, one per AZ). No internet route. |
| `availability_zone_ids` | us-east-1 supported set | AZ **IDs** the subnets may use. Runtime VPC mode is AZ-restricted; set per Region. |
| `target_name` | `web-search` | Determines the tool name `<target_name>___WebSearch`. |
| `connector_version` | `1.2.0` | `1.2.0` adds the include list and request-level filters. |
| `mcp_supported_versions` | `["2025-11-25"]` | MCP versions the Gateway accepts. Default is the latest MCP revision. |
| `enable_semantic_search` | `true` | Gateway `search_type = SEMANTIC` — context-based tool discovery. **Creation-only** (see note below). |
| `enable_response_streaming` | `true` | Gateway streams tool responses incrementally over MCP. |
| `enable_gateway_tracing` | `true` | Deliver Gateway spans (TRACES) to X-Ray. Requires account-level Transaction Search. |
| `enable_runtime_tracing` | `true` | Deliver Runtime spans (TRACES) to X-Ray. Requires account-level Transaction Search. |
| `log_retention_days` | `30` | Retention for the Gateway application-logs log group. |
| `domain_include` / `domain_exclude` | `[]` | Target-level domain governance (hidden from the agent). |
| `connect_timeout_seconds` | `30` | Agent's connect timeout to the Gateway. |

> **`enable_semantic_search` is creation-only.** The service rejects adding
> `SEMANTIC` to a Gateway that already has a target
> (`ValidationException: Search type cannot be updated to SEMANTIC for a gateway
> with 1 or more targets`). On a fresh deploy it is set at creation and just
> works. Toggling it on an existing stack requires **replacing the Gateway**:
> `terraform apply -replace=aws_bedrockagentcore_gateway.web_search`. The
> Gateway's URL/ARN then changes, so the VPC endpoint policy, the runtime role,
> and the runtime's `GATEWAY_MCP_URL` all update — and the endpoint policy takes
> a few minutes to propagate, during which the agent may see a transient `403`.

## Observability

### Gateway

The Gateway's logs and traces are wired explicitly (AgentCore auto-creates a log
group for a *Runtime* but not for a *Gateway*):

- **Application logs** → a CloudWatch log group
  (`gateway_log_group_name` output): tool invocations, request params, responses,
  and errors, each tagged with `trace_id`/`span_id`/`request_id`.
- **Traces (spans)** → X-Ray / CloudWatch Transaction Search, viewable on the
  CloudWatch **GenAI Observability** page.

### Runtime

Like the Gateway, the Runtime needs **explicit vended-log delivery** — the
auto-created `/aws/bedrock-agentcore/runtimes/<id>-DEFAULT` service group stays
empty and the console/GenAI-Observability panes report logging/tracing as *not
enabled* until a delivery is configured.

- **Logs** → a CloudWatch vended-logs group
  (`runtime_log_group_name` output,
  `/aws/vendedlogs/bedrock-agentcore/runtime/APPLICATION_LOGS/<id>`) via an
  `APPLICATION_LOGS` delivery source/destination/delivery. Records carry
  `trace_id`, `span_id`, and `session_id`.
- **Traces** need two things together: (1) the agent **emitting** spans, and
  (2) a **delivery** for them. The agent image is instrumented with the AWS
  Distro for OpenTelemetry (`aws-opentelemetry-distro` in
  `agent/requirements.txt`, launched via `opentelemetry-instrument` in the
  Dockerfile) so Strands, the Bedrock model calls, and the MCP calls to the
  Gateway are auto-traced; a `TRACES` delivery source/destination then ships
  those spans to X-Ray / Transaction Search and the GenAI Observability page,
  correlated by trace ID. The execution role already carries the required
  `xray:PutTraceSegments` and `logs:PutResourcePolicy` permissions.

Both trace paths require **CloudWatch Transaction Search** enabled once per
account+Region. This sample does not flip that account-wide switch; if it is off,
enable it (and set `enable_gateway_tracing = false` until then):

```bash
aws xray update-trace-segment-destination --destination CloudWatchLogs --region <region>
```

When Transaction Search is on, the CloudWatch Logs delivery service auto-manages
the X-Ray resource policy for `delivery.logs.amazonaws.com`, so there is nothing
extra to grant.

## Cost

| Item | Rate |
| --- | --- |
| Web Search queries | **$7.00 per 1,000 queries** — the dominant line item |
| AgentCore Runtime | per-second compute while a session is active |
| Bedrock model tokens | per the model's input/output token rates |
| Interface VPC endpoints | per-endpoint-hour + per-GB processed, per AZ |
| S3 gateway endpoint | **free** |
| Gateway API invocations | $0.005 per 1,000 |
| Semantic search (`enable_semantic_search`) | $0.025 per 1,000 search calls + $0.02 per 100 tools indexed/month |
| CloudWatch Logs / X-Ray | ingestion + storage for Gateway logs and spans |

The interface endpoints carry a standing hourly charge **per AZ** for as long as
they exist — this is the main difference from the Gateway-only sample, which had
no standing cost. Tear down when finished. Confirm current rates on the
[AgentCore pricing page](https://aws.amazon.com/bedrock/agentcore/pricing).

## Security posture

- **No internet path.** The route table has no `0.0.0.0/0` route; subnets never
  auto-assign public IPs; there is no IGW or NAT. Egress is physically limited to
  the VPC endpoints.
- **Security groups are least-privilege.** The runtime SG egresses 443 only to
  the endpoint SG; the endpoint SG ingresses 443 only from the runtime SG. No
  rule references `0.0.0.0/0`.
- **Endpoint policies scope both Principal and Resource** on the Gateway and
  Bedrock endpoints — possible because inbound auth is `AWS_IAM`. The S3 gateway
  endpoint is scoped to just the ECR layer bucket.
- **Two IAM boundaries, separate roles.** The Gateway *service* role handles
  outbound auth to Web Search; the runtime *execution* role handles the agent's
  identity (model + `InvokeGateway`). Neither is broader than it needs to be.
- The agent's container binds `0.0.0.0:8080`. That is the AgentCore HTTP
  contract — AgentCore reaches the agent across the container boundary over its
  managed data path, and the port is **not** published to any network. The
  privacy boundary is the VPC and its endpoints, not the in-container bind.

## Deliberate simplifications

| Omitted | Why, and what adding it costs |
| --- | --- |
| **Customer-managed KMS keys** | The Gateway and ECR use AWS-owned/-managed keys. A CMK on the Gateway needs a key policy referencing the Gateway ARN, which can't be expressed in a single apply (dependency cycle). |
| **Private invoke path by default** | The invoke script calls the public data-plane endpoint. The `bedrock-agentcore` data-plane endpoint is created, so you *can* invoke privately from inside the VPC — the sample just doesn't stand up a bastion to do so. |
| **AgentCore Memory** | No Memory wiring. Gateway logs and traces *are* delivered (see Observability). For a full audit trail, also enable CloudTrail data events for `bedrock-agentcore.amazonaws.com`. |
| **OAuth/JWT inbound auth** | `AWS_IAM` is used throughout. It is also the stronger private-ingress posture: JWT inbound forces the endpoint-policy Principal to `"*"`. |
| **A separate named runtime endpoint** | AgentCore auto-creates the `DEFAULT` endpoint. Add a named `aws_bedrockagentcore_agent_runtime_endpoint` for pinned prod/staging aliases. |

## Troubleshooting

**`CreateAgentRuntime` fails: "subnets are in unsupported availability zones"**
— AgentCore Runtime VPC mode runs only in specific AZs, and an account's AZ
*names* map to different AZ *IDs*. This sample selects subnet AZs by stable AZ
**ID** via `availability_zone_ids` (default `use1-az1`, `use1-az2`, `use1-az4`
for us-east-1). For another Region, set it to that Region's supported IDs — see
the [Supported Availability Zones table](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-vpc.html).

**Runtime stuck / `Failed to pull image ... dial tcp <s3-ip>:443: i/o timeout`**
— the image-layer pull from S3 is being dropped. S3 is reached through the
**gateway** endpoint via the route table and the S3 *prefix list*, not through an
ENI in the endpoint security group — so the runtime SG needs an explicit egress
rule to the S3 prefix list (this sample's `runtime_egress_to_s3`). A runtime SG
that only allows egress to the interface-endpoint SG will pull-timeout here.

**`InvokeAgentRuntime` fails right after apply** — the runtime needs a short time
to reach `READY`. Wait a minute and retry.

**Agent response has `gateway_status: error ...`** — the agent started but could
not reach the Gateway or the model. Check the runtime logs:

```bash
aws logs tail /aws/bedrock-agentcore/runtimes/ --follow --region <region>
```

Common causes: the model in `bedrock_model_id` is not entitled in this account/
Region; or the Gateway target did not provision (`terraform output tool_name`
then list the Gateway targets).

**Runtime stuck starting / image pull errors** — confirm the S3 gateway endpoint
and both ECR endpoints exist and that buildx produced a `linux/arm64` image
(`terraform output agent_image_uri`, then `docker buildx imagetools inspect`).

**`Blocks of type "connector" are not expected here`** — AWS provider predates
6.63.0. Run `terraform init -upgrade`.

**Conflicting DNS domain when creating endpoints** — you already have a
private-DNS interface endpoint for the *same* service in this VPC. The
data-plane (`bedrock-agentcore`) and Gateway (`*.gateway.bedrock-agentcore`)
services are distinct and don't conflict with each other, but a pre-existing
endpoint for one of them will. Remove it or disable its private DNS.

## Clean Up

```bash
./destroy.sh
```

Removes the runtime, Gateway, VPC + all endpoints, the ECR repo (and its
images), and every IAM role created here. The interface-endpoint hourly charge
stops as soon as they are gone.

## References

- [Use interface VPC endpoints (AWS PrivateLink) for AgentCore](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/vpc-interface-endpoints.html)
- [Configure AgentCore Runtime and tools for VPC](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-vpc.html)
- [Security best practices for AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-security-best-practices.html)
- [IAM permissions for AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html)
- [HTTP protocol contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-http-protocol-contract.html)
- [Web Search Tool](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-target-connector-web-search-tool.html)
- [Secure ingress to AgentCore Gateway using interface VPC endpoints](https://aws.amazon.com/blogs/machine-learning/secure-ingress-connectivity-to-amazon-bedrock-agentcore-gateway-using-interface-vpc-endpoints/)
