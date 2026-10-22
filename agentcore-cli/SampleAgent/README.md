# A Strands agent to AgentCore Runtime or AgentCore Harness

## Runtime

`provision-runtime.sh` — Deploy a Strands agent to AgentCore Runtime (not Harness).


Uses the AgentCore CLI scaffolding which generates main.py with proper
Strands + ADOT instrumentation out of the box. Then adds:
  - Memory (SEMANTIC + SUMMARIZATION)
  - Gateway with 2 MCP tool targets (managed Web Search + AWS Knowledge MCP)
  - UNIFIED_TRACES_DESTINATION_ENABLED=true

Unlike Harness, Runtime agents produce spans compatible with the evaluators.

EVALUATION IS SEPARATE. This script only provisions the agent. To score agents, use the dataset-driven BATCH evaluation workflow (see readme.md "Evaluation"):

```bash
  ./create-eval-evaluators.sh --profile <profile>     one-time: 6 custom judges
  ./evaluate-agents.sh --profile <profile> --team <team>
```

Usage:

```bash
  ./provision-runtime.sh --name TeamAlpha --profile team-alpha --region us-east-1
  ./provision-runtime.sh --name TeamBeta --profile team-beta --region eu-west-1
./provision-runtime.sh --name TeamAlpha --profile team1 --region us-east-1 --model-id amazon.nova-pro-v1:0
./provision-runtime.sh --name TeamBeta --profile team2 --region us-east-1 --model-id amazon.nova-lite-v1:0
```


## Harness

Usage:

```bash
#   ./provision-harness.sh
#   ./provision-harness.sh --profile my-aws-profile
#   ./provision-harness.sh --region us-west-2 --profile hackathon-team1
#   ./provision-harness.sh --name MyTeamAgent --region eu-west-1
```
