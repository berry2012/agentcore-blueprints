# AgentCore CLI and AWS CLI blueprints

Blueprints in this folder are shell scripts that drive the
[AgentCore CLI](https://github.com/aws/agentcore-cli) and the AWS CLI to deploy agents end
to end. They're the quickest way to get an agent running on Amazon Bedrock AgentCore, and
a readable reference for the CLI commands behind each step.

Each script is safe to re-run: it checks what already exists before creating anything,
and every provision script has a matching cleanup script.

## Blueprints

| Blueprint | What it shows | AgentCore features |
| --- | --- | --- |
| [SampleAgent](SampleAgent/) | Deploys a Strands agent to AgentCore Runtime or AgentCore Harness, then wires in Memory and a Gateway with MCP tool targets (Web Search, Exa, AWS Knowledge MCP). | Runtime, Harness, Memory, Gateway, Observability |

## Prerequisites

- An AWS account with access to Amazon Bedrock AgentCore, and Bedrock model access in
  your Region
- The [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
  configured with a profile that can create IAM roles and AgentCore resources
- The [AgentCore CLI](https://github.com/aws/agentcore-cli) (`agentcore` on your `PATH`)
- Bash and Python 3, which the scripts use to read the AgentCore project config

Each blueprint's README lists anything extra it needs, such as Region limits.

## Usage

```bash
cd agentcore-cli/<blueprint-name>
./provision-<variant>.sh --name <agent-name> --profile <aws-profile> --region <region>
./cleanup-<variant>.sh --name <agent-name> --profile <aws-profile> --region <region>
```

Pass the same `--name` and `--region` to cleanup that you used to provision, so it finds
the right resources.

Run the cleanup script when you're done. These blueprints create resources that incur
charges while they exist.

## Adding a blueprint

Put it in its own folder here and follow [CONTRIBUTING.md](../CONTRIBUTING.md). Take the
AWS profile and Region as arguments, derive the account ID at runtime, and ship a cleanup
script for everything you create.
