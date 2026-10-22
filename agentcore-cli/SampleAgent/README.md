# A Strands agent on AgentCore Runtime or AgentCore Harness

Scripts that use the [AgentCore CLI](https://github.com/aws/agentcore-cli) and the AWS CLI
to deploy an agent end to end, with Memory and a Gateway of MCP tools attached. There are
two paths: Runtime (your own Strands agent code) and Harness (a managed agent loop).

> [!WARNING]
> Both scripts create the AgentCore Gateway with `--authorizer-type NONE`. The Gateway
> endpoint accepts requests without any authentication, so anyone who learns its URL can
> list and call its tools. This keeps the sample simple, but use it only for short-lived
> demos or workshops, don't attach tools that reach private data or perform actions, and
> run the cleanup script when you're done. For anything longer-lived, use `AWS_IAM` or JWT
> inbound auth instead.

## Runtime

`provision-runtime.sh` deploys a Strands agent to AgentCore Runtime. It uses the AgentCore
CLI scaffolding, which generates `main.py` with Strands and ADOT instrumentation, then adds:

- Memory (SEMANTIC + SUMMARIZATION)
- A Gateway with two MCP tool targets: the AWS-managed Web Search connector and the AWS
  Knowledge MCP server
- `UNIFIED_TRACES_DESTINATION_ENABLED=true`, so traces land in CloudWatch

The managed Web Search connector is only available in `us-east-1`, so deploy this path
there. The script warns you if you pick another Region.

```bash
./provision-runtime.sh --name TeamAlpha --profile team-alpha --region us-east-1
./provision-runtime.sh --name TeamBeta --profile team-beta --region us-east-1 --model-id amazon.nova-lite-v1:0
```

Cleanup:

```bash
./cleanup-runtime.sh --name TeamAlpha --profile team-alpha --region us-east-1
```

## Harness

`provision-harness.sh` deploys an AgentCore Harness agent backed by a Bedrock model, plus:

- Memory (SEMANTIC + SUMMARIZATION)
- A Gateway with two MCP tool targets: Exa search (`https://mcp.exa.ai/mcp`) and the AWS
  Knowledge MCP server. Exa's hosted MCP server has a free tier, so no API key is needed.

```bash
./provision-harness.sh
./provision-harness.sh --profile my-aws-profile
./provision-harness.sh --name MyTeamAgent --region us-west-2
```

Cleanup:

```bash
./cleanup-harness.sh --name MyTeamAgent --region us-west-2
```

## Options

Both provision scripts accept `--name`, `--region`, `--profile`, `--model-id`, and
`--system-prompt`. To run the agent in your own VPC, pass `--network-mode VPC` with
`--subnets` and `--security-groups`. The defaults are `--name HackathonAgent` and
`--region us-east-1`.

If your account hasn't enabled Anthropic models in the Region yet, run
`./enable-anthropic-models.sh <region>` once first.
