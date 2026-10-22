# AgentCore Blueprints

A public catalog of sample solutions, reference architectures, and reusable artifacts
for [Amazon Bedrock AgentCore](https://aws.amazon.com/bedrock/agentcore/). Each
blueprint is a self-contained, deployable example you can stand up in your own AWS
account, read end to end, and adapt to your own use case. The focus is on patterns that
are small enough to understand in one sitting but complete enough to run: infrastructure
as code, least-privilege IAM, a way to verify the deployment, and a way to tear it down.

## What is Amazon Bedrock AgentCore

Amazon Bedrock AgentCore is a set of managed services for building, deploying, and
operating AI agents at scale, including a serverless Runtime, Gateway for exposing tools
over MCP, Memory, Identity, Observability, and built-in tools such as Web Search, Code
Interpreter, and Browser. It works with any agent framework and any model. See the
[product page](https://aws.amazon.com/bedrock/agentcore/) and the
[developer guide](https://docs.aws.amazon.com/bedrock-agentcore/).

## Blueprints

| Blueprint | Category | Description | Stack/Tools |
| --- | --- | --- | --- |
| [web-search-gateway](infrastructure-as-code/terraform/web-search-gateway/) | Infrastructure as code / Gateway | Provisions an AgentCore Gateway with the AWS-managed Web Search connector in a single `terraform apply`. Uses `AWS_IAM` (SigV4) inbound auth, a least-privilege caller role, a separate Gateway service role for outbound auth, and optional target-level domain allow/deny lists. Includes a Python MCP client that proves the tool returns live results without deploying an agent. | Terraform >= 1.6, AWS provider ~> 6.69, AWS CLI, Python 3.11+ with boto3/botocore |
| [agentcore-private-websearch-tf](infrastructure-as-code/terraform/agentcore-private-websearch-tf/) | Infrastructure as code / Runtime + Gateway | Deploys a Strands agent (TechEventsFinder) to AgentCore Runtime inside a VPC with no internet or NAT gateway. The agent reaches Bedrock and the AgentCore Gateway Web Search tool only through AWS PrivateLink interface endpoints, with endpoint policies scoped to the runtime role and this Gateway. Includes OpenTelemetry tracing to CloudWatch and an invoke script. | Terraform >= 1.6, AWS provider ~> 6.69, Docker, AWS CLI, Python with boto3 |

More blueprints are on the way. Watch this table or the folders below as they land.

## Repository structure

```text
agentcore-blueprints/
├── LICENSE
├── README.md
└── infrastructure-as-code/
    └── terraform/
        ├── web-search-gateway/
        │   ├── README.md
        │   ├── architecture.png
        │   ├── *.tf
        │   ├── deploy.sh
        │   ├── destroy.sh
        │   └── scripts/
        └── agentcore-private-websearch-tf/
            ├── README.md
            ├── *.tf
            ├── agent/
            ├── deploy.sh
            ├── destroy.sh
            └── scripts/
```

Convention for infrastructure blueprints:

```text
infrastructure-as-code/<tool>/<blueprint-name>/
```

`<tool>` is `terraform` today; `cdk` and `cloudformation` are reserved for future
blueprints. Other top-level categories (for example `agents`, `gateways`, `memory`,
`identity`, `observability`, `notebooks`) may be added as blueprints land. Directories are
created only when a blueprint ships in them.

## Getting started

General prerequisites:

- An AWS account with access to Amazon Bedrock AgentCore in a
  [supported Region](https://docs.aws.amazon.com/bedrock-agentcore/). Some features,
  such as the Web Search connector, are available in a subset of Regions; each blueprint
  README lists what it needs.
- AWS CLI installed and configured with credentials that can create the resources the
  blueprint provisions (typically IAM roles and AgentCore resources).
- Per-blueprint tooling, listed in each blueprint's README. For Terraform blueprints
  this means Terraform >= 1.6 and, where a test client is included, Python 3 with boto3.

To deploy a blueprint:

```bash
git clone https://github.com/berry2012/agentcore-blueprints.git
cd agentcore-blueprints/infrastructure-as-code/terraform/web-search-gateway
```

Then follow that folder's README. Each blueprint documents its own deploy, verify, and
cleanup steps, and most ship a `deploy.sh` and `destroy.sh` to make them one command each.

## Contributing

Contributions are welcome. Open a pull request with your blueprint in its own folder
following the structure above. Each blueprint must be self-contained and include a
`README.md` covering:

- Overview of what it deploys and why
- Architecture diagram, if available
- Prerequisites (tooling, versions, Regions, IAM permissions)
- Deploy steps
- Test or verify steps
- Cleanup or destroy steps
- Cost notes

Never commit secrets, credentials, `terraform.tfstate`, or `.terraform/` directories.
Provide `*.example` files for anything environment-specific (for example
`terraform.tfvars.example`, `backend.tf.example`) and ship a `.gitignore` in the
blueprint folder.

## Security

These blueprints are reference samples, not production-ready deployments. Before using
them beyond a proof of concept, review the IAM policies they create, confirm Region and
service availability, and check the pricing of every service involved. Many blueprints
create resources that incur charges while they exist or per invocation; run the
documented cleanup step when you are done.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
