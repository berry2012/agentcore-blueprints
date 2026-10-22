# AgentCore Blueprints

[![Secret scan](https://github.com/berry2012/agentcore-blueprints/actions/workflows/secret-scan.yml/badge.svg?branch=main)](https://github.com/berry2012/agentcore-blueprints/actions/workflows/secret-scan.yml) [![IaC checks](https://github.com/berry2012/agentcore-blueprints/actions/workflows/iac.yml/badge.svg?branch=main)](https://github.com/berry2012/agentcore-blueprints/actions/workflows/iac.yml) [![CodeQL](https://github.com/berry2012/agentcore-blueprints/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/berry2012/agentcore-blueprints/actions/workflows/codeql.yml)

A public collection of sample solutions, reference architectures, and reusable artifacts
for [Amazon Bedrock AgentCore](https://aws.amazon.com/bedrock/agentcore/).

Blueprints come in whatever form fits the pattern best: infrastructure as code,
AgentCore CLI and AWS CLI scripts, agent code, and more over time. Each one is
self-contained and runnable in your own AWS account, with a way to verify it works and a
way to tear it down.

## What is Amazon Bedrock AgentCore

Amazon Bedrock AgentCore is a set of managed services for building, deploying, and
operating AI agents at scale, including a serverless Runtime, Gateway for exposing tools
over MCP, Memory, Identity, Observability, and built-in tools such as Web Search, Code
Interpreter, and Browser. It works with any agent framework and any model. See the
[product page](https://aws.amazon.com/bedrock/agentcore/) and the
[developer guide](https://docs.aws.amazon.com/bedrock-agentcore/).

## Blueprints

### AgentCore CLI and AWS CLI

Scripted, end-to-end deployments driven by the [AgentCore CLI](https://github.com/aws/agentcore-cli)
and the AWS CLI. A good starting point if you want an agent running quickly.

| Blueprint | What it shows | AgentCore features |
| --- | --- | --- |
| [SampleAgent](agentcore-cli/SampleAgent/) | Deploys a Strands agent to AgentCore Runtime or AgentCore Harness with one script, then wires in Memory and a Gateway with MCP tool targets. Includes cleanup scripts for both paths. | Runtime, Harness, Memory, Gateway, Observability |

### Infrastructure as code

Repeatable deployments you can review, version, and plug into a pipeline.

| Blueprint | What it shows | AgentCore features | Tooling |
| --- | --- | --- | --- |
| [web-search-gateway](infrastructure-as-code/terraform/web-search-gateway/) | A Gateway exposing the AWS-managed Web Search tool over MCP with SigV4 (`AWS_IAM`) inbound auth and least-privilege roles. A Python MCP client proves it works without deploying an agent. | Gateway, Web Search | Terraform |
| [agentcore-private-websearch-tf](infrastructure-as-code/terraform/agentcore-private-websearch-tf/) | A Strands agent on Runtime inside a VPC with no internet or NAT gateway. It reaches Bedrock and the Web Search Gateway only over AWS PrivateLink, with endpoint policies scoped to the runtime role. | Runtime, Gateway, Web Search, Observability | Terraform, Docker |

More blueprints are on the way.

## Getting started

You'll need:

- An AWS account with access to Amazon Bedrock AgentCore in a
  [supported Region](https://docs.aws.amazon.com/bedrock-agentcore/). Some features,
  such as Web Search or Harness, are available in a subset of Regions.
- The AWS CLI, configured with credentials that can create the resources the blueprint
  provisions.
- The tooling listed in the blueprint's own README (for example the AgentCore CLI,
  Terraform, Docker, or Python).

Then clone the repo and open the blueprint you want:

```bash
git clone https://github.com/berry2012/agentcore-blueprints.git
cd agentcore-blueprints/<path-to-blueprint>
```

Each blueprint's README walks through deploy, verify, and cleanup.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how blueprints are
organized, what each one needs, and the checks that run on pull requests.

## Security

These blueprints are reference samples, not production-ready deployments. Before using
them beyond a proof of concept, review the IAM policies and auth settings they create,
confirm Region and service availability, and check the pricing of every service involved.
Most blueprints create resources that incur charges while they exist or per invocation,
so run the documented cleanup step when you are done.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
