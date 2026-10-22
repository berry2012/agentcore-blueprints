#!/usr/bin/env bash
# provision-runtime.sh — Deploy a Strands agent to AgentCore Runtime (not Harness).
#
# Uses the AgentCore CLI scaffolding which generates main.py with proper
# Strands + ADOT instrumentation out of the box. Then adds:
#   - Memory (SEMANTIC + SUMMARIZATION)
#   - Gateway with 2 MCP tool targets (managed Web Search + AWS Knowledge MCP)
#   - UNIFIED_TRACES_DESTINATION_ENABLED=true
#
# Usage:
#   ./provision-runtime.sh --name TeamAlpha --profile team-alpha --region us-east-1
#   ./provision-runtime.sh --name TeamBeta --profile team-beta --region eu-west-1
# ./provision-runtime.sh --name TeamAlpha --profile team1 --region us-east-1 --model-id amazon.nova-pro-v1:0
# ./provision-runtime.sh --name TeamBeta --profile team2 --region us-east-1 --model-id amazon.nova-lite-v1:0

#
set -euo pipefail

export AGENTCORE_SUPPRESS_RECOMMENDATION=1
export AWS_PAGER=""

# ─── Script directory ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ────────────────────────────────────────────────────────────────
AGENT_NAME="HackathonAgent"
REGION="us-east-1"
AWS_PROFILE_ARG=""
NETWORK_MODE="PUBLIC"
SUBNETS=""
SECURITY_GROUPS=""
MODEL_ID=""
SYSTEM_PROMPT="You are a helpful research assistant. You can search the web for current information and access AWS documentation to help users with their queries. Always cite your sources."

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --name) AGENT_NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --profile) AWS_PROFILE_ARG="--profile $2"; export AWS_PROFILE="$2"; shift 2 ;;
    --network-mode) NETWORK_MODE="$2"; shift 2 ;;
    --subnets) SUBNETS="$2"; shift 2 ;;
    --security-groups) SECURITY_GROUPS="$2"; shift 2 ;;
    --model-id) MODEL_ID="$2"; shift 2 ;;
    --system-prompt) SYSTEM_PROMPT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Provision an AgentCore Runtime agent (Strands) with gateway and memory."
      echo ""
      echo "Options:"
      echo "  --name NAME                  Agent/project name (default: HackathonAgent)"
      echo "  --region REGION              AWS region (default: us-east-1)"
      echo "  --profile PROFILE            AWS CLI profile to use (isolates accounts)"
      echo "  --network-mode MODE          Network mode: PUBLIC or VPC (default: PUBLIC)"
      echo "  --subnets IDS                Comma-separated subnet IDs (required for VPC)"
      echo "  --security-groups IDS        Comma-separated security group IDs (required for VPC)"
      echo "  --model-id MODEL_ID          Bedrock model ID (default: auto-detected based on region)"
      echo "  --system-prompt PROMPT       Custom system prompt"
      echo "  -h, --help                   Show this help"
      echo ""
      echo "Examples:"
      echo "  ./provision-runtime.sh --name TeamAlpha --profile team-alpha --region us-east-1"
      echo "  ./provision-runtime.sh --name TeamBeta --profile team-beta --region eu-west-1"
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Validate VPC arguments ──────────────────────────────────────────────────
if [[ "${NETWORK_MODE}" == "VPC" ]]; then
  if [[ -z "${SUBNETS}" || -z "${SECURITY_GROUPS}" ]]; then
    echo "ERROR: --network-mode VPC requires both --subnets and --security-groups"
    exit 1
  fi
fi

# ─── Determine model ID based on region ──────────────────────────────────────
# Default to Claude Sonnet 4.5 (invokable in the hackathon team accounts). Sonnet 5
# is NOT entitled in these accounts and returns AccessDeniedException on invoke.
if [[ -z "${MODEL_ID}" ]]; then
  if [[ "${REGION}" == eu-* ]]; then
    MODEL_ID="eu.anthropic.claude-sonnet-4-5-20250929-v1:0"
  elif [[ "${REGION}" == ap-* ]]; then
    MODEL_ID="apac.anthropic.claude-sonnet-4-5-20250929-v1:0"
  else
    MODEL_ID="us.anthropic.claude-sonnet-4-5-20250929-v1:0"
  fi
fi

# ─── Validate AWS credentials ────────────────────────────────────────────────
echo "=============================================="
echo " AgentCore Runtime Agent Provisioning"
echo "=============================================="
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity ${AWS_PROFILE_ARG} --query Account --output text --region "${REGION}") || {
  echo "ERROR: Cannot determine AWS account. Check your AWS credentials/profile and try again."
  exit 1
}

echo "  Agent:   ${AGENT_NAME}"
echo "  Type:    Runtime (Strands + CodeZip)"
echo "  Region:  ${REGION}"
echo "  Account: ${ACCOUNT_ID}"
echo "  Model:   ${MODEL_ID}"
echo "  Profile: ${AWS_PROFILE:-default}"
echo ""

# ─── Web Search connector region guard ───────────────────────────────────────
# The managed AgentCore Web Search tool (connectorId: web-search) is offered in
# us-east-1 ONLY. The gateway must be created there for the connector target to
# attach, regardless of where the rest of the stack lives.
# Ref: https://aws.amazon.com/blogs/machine-learning/introducing-web-search-on-amazon-bedrock-agentcore/
if [[ "${REGION}" != "us-east-1" ]]; then
  echo "  WARNING: The managed Web Search connector is only available in us-east-1."
  echo "           Region '${REGION}' will fail to attach the 'web-search' target."
  echo "           Re-run with --region us-east-1, or the deploy will stop at target creation."
  echo ""
fi

export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"

DEPLOY_DIR="${SCRIPT_DIR}/deploy-rt-${AGENT_NAME}"

# ─── [1/7] Enable CloudWatch Transaction Search ──────────────────────────────
echo "[1/7] Ensuring CloudWatch Transaction Search is enabled..."

TXSEARCH_STATUS=$(aws observabilityadmin get-telemetry-evaluation-status ${AWS_PROFILE_ARG} --region "${REGION}" \
  --query "Status" --output text 2>/dev/null || echo "UNKNOWN")

if [[ "${TXSEARCH_STATUS}" == "NOT_STARTED" ]]; then
  aws observabilityadmin start-telemetry-evaluation ${AWS_PROFILE_ARG} --region "${REGION}" 2>/dev/null || true
  echo "  Transaction Search enabled."
elif [[ "${TXSEARCH_STATUS}" == "RUNNING" ]]; then
  echo "  Transaction Search already enabled."
else
  echo "  Transaction Search status: ${TXSEARCH_STATUS}"
fi
echo ""

# ─── [2/7] Scaffold project with AgentCore CLI ───────────────────────────────
echo "[2/7] Scaffolding Runtime project: ${AGENT_NAME}..."

if [[ -d "${DEPLOY_DIR}" ]]; then
  echo "  Deploy directory already exists: ${DEPLOY_DIR}"
  echo "  Reusing existing project..."
else
  cd "${SCRIPT_DIR}"

  VPC_FLAGS=""
  if [[ "${NETWORK_MODE}" == "VPC" ]]; then
    VPC_FLAGS="--network-mode VPC --subnets ${SUBNETS} --security-groups ${SECURITY_GROUPS}"
  fi

  agentcore create \
    --name "${AGENT_NAME}" \
    --framework Strands \
    --model-provider Bedrock \
    --memory none \
    --build CodeZip \
    ${VPC_FLAGS}

  mv "${AGENT_NAME}" "${DEPLOY_DIR}" 2>/dev/null || true
  echo "  Project scaffolded at: ${DEPLOY_DIR}"
fi

cd "${DEPLOY_DIR}"

# Configure deployment target
python3 -c "
import json
targets = [{'name': 'default', 'description': 'Hackathon deployment (${REGION})', 'account': '${ACCOUNT_ID}', 'region': '${REGION}'}]
with open('agentcore/aws-targets.json', 'w') as f:
    json.dump(targets, f, indent=2)
"
echo "  Set region=${REGION}, account=${ACCOUNT_ID} in aws-targets.json"
echo ""

# ─── [3/7] Update scaffolded main.py with model + system prompt ───────────────
echo "[3/7] Configuring agent code (model + system prompt)..."

APP_DIR="${DEPLOY_DIR}/app/${AGENT_NAME}"

# Update the scaffolded main.py to use our model and system prompt
# The CLI generates a working main.py — we just update the model_id and system_prompt
python3 << PYUPDATE
import sys, os

app_dir = "${APP_DIR}"
main_py = os.path.join(app_dir, "main.py")

# Read existing scaffolded code
with open(main_py) as f:
    content = f.read()

# Replace model_id if present in the scaffolded code
model_id = "${MODEL_ID}"
region = "${REGION}"
system_prompt = """${SYSTEM_PROMPT}"""

# Check if the scaffolded code has a model_id reference we can update
if "model_id" in content or "BedrockModel" in content:
    # Replace any existing model_id string
    import re
    # Match model_id="..." pattern
    content = re.sub(
        r'model_id\s*=\s*"[^"]*"',
        f'model_id="{model_id}"',
        content
    )
    # Match region_name="..." pattern
    content = re.sub(
        r'region_name\s*=\s*"[^"]*"',
        f'region_name="{region}"',
        content
    )
    # Try to update system_prompt if present
    if "system_prompt" in content:
        content = re.sub(
            r'system_prompt\s*=\s*"[^"]*"',
            f'system_prompt="{system_prompt}"',
            content
        )
    with open(main_py, 'w') as f:
        f.write(content)
    print("  Updated model_id and region in scaffolded main.py")
else:
    print("  Scaffolded main.py doesn't match expected pattern, leaving as-is")
    print("  Will set via environment variables instead")
PYUPDATE

# Set environment variables in agentcore.json as fallback
python3 << PYENV
import json
config_file = '${DEPLOY_DIR}/agentcore/agentcore.json'
with open(config_file) as f:
    config = json.load(f)
for rt in config.get('runtimes', []):
    if 'environment' not in rt:
        rt['environment'] = {}
    rt['environment']['MODEL_ID'] = '${MODEL_ID}'
    rt['environment']['AWS_REGION'] = '${REGION}'
    rt['environment']['UNIFIED_TRACES_DESTINATION_ENABLED'] = 'true'
    rt['description'] = 'Hackathon Runtime Agent - ${AGENT_NAME}'
with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)
PYENV

echo "  Environment: MODEL_ID=${MODEL_ID}, UNIFIED_TRACES_DESTINATION_ENABLED=true"
echo ""

# ─── [4/7] Add Memory ────────────────────────────────────────────────────────
echo "[4/7] Adding Memory (SEMANTIC + SUMMARIZATION)..."

cd "${DEPLOY_DIR}"

HAS_MEMORY=$(python3 -c "
import json
with open('agentcore/agentcore.json') as f:
    config = json.load(f)
print('yes' if config.get('memories', []) else 'no')
" 2>/dev/null || echo "no")

if [[ "${HAS_MEMORY}" == "no" ]]; then
  agentcore add memory \
    --name "${AGENT_NAME}_memory" \
    --strategies SEMANTIC,SUMMARIZATION
  echo "  Memory added: ${AGENT_NAME}_memory"
else
  echo "  Memory already configured."
fi
echo ""

# ─── [5/7] Create Gateway with MCP targets ───────────────────────────────────
echo "[5/7] Creating Gateway with MCP tool targets..."

cd "${DEPLOY_DIR}"
GW_NAME="${AGENT_NAME}-gateway"

HAS_GATEWAY=$(python3 -c "
import json
with open('agentcore/agentcore.json') as f:
    config = json.load(f)
print('yes' if config.get('agentCoreGateways', []) else 'no')
" 2>/dev/null || echo "no")

if [[ "${HAS_GATEWAY}" == "no" ]]; then
  agentcore add gateway --name "${GW_NAME}" --authorizer-type NONE
  echo "  Gateway created: ${GW_NAME}"
fi

# Web Search target (managed AgentCore connector — replaces EXA)
# Uses the fully managed Web Search tool on Amazon Bedrock AgentCore
# (connectorId: web-search). No API keys, no external MCP endpoint — the Gateway
# authenticates to the AWS-owned Web Search backend via its GATEWAY_IAM_ROLE, and
# queries never leave AWS. Available in us-east-1 at time of writing.
# Ref: https://aws.amazon.com/blogs/machine-learning/introducing-web-search-on-amazon-bedrock-agentcore/
HAS_WEBSEARCH=$(python3 -c "
import json
with open('agentcore/agentcore.json') as f:
    config = json.load(f)
for gw in config.get('agentCoreGateways', []):
    for t in gw.get('targets', []):
        name = t.get('name', '').lower()
        if 'web-search' in name or 'websearch' in name:
            print('yes'); exit()
print('no')
" 2>/dev/null || echo "no")

if [[ "${HAS_WEBSEARCH}" == "no" ]]; then
  agentcore add gateway-target \
    --name "web-search" \
    --type connector \
    --connector web-search \
    --gateway "${GW_NAME}"
  echo "  Web Search connector target added (managed AgentCore web search)."
else
  echo "  Web Search target already configured."
fi

# AWS Knowledge MCP target
HAS_AWS=$(python3 -c "
import json
with open('agentcore/agentcore.json') as f:
    config = json.load(f)
for gw in config.get('agentCoreGateways', []):
    for t in gw.get('targets', []):
        if 'aws' in t.get('name', '').lower():
            print('yes'); exit()
print('no')
" 2>/dev/null || echo "no")

if [[ "${HAS_AWS}" == "no" ]]; then
  agentcore add gateway-target \
    --name "aws-knowledge-mcp" \
    --type mcp-server \
    --endpoint "https://knowledge-mcp.global.api.aws" \
    --gateway "${GW_NAME}"
  echo "  AWS Knowledge MCP target added."
fi
echo ""

# ─── [6/7] Deploy ────────────────────────────────────────────────────────────
echo "[6/7] Deploying to AgentCore Runtime..."
echo ""

cd "${DEPLOY_DIR}"
agentcore deploy -y -v

echo ""

# ─── [7/7] Enable Gateway Observability ──────────────────────────────────────
echo "[7/7] Enabling Gateway Observability..."

# list-gateways doesn't return ARN, so get the gateway ID first then use get-gateway
GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways ${AWS_PROFILE_ARG} --region "${REGION}" \
  --query "items[?contains(name,'${GW_NAME}')].gatewayId | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "${GATEWAY_ID}" != "None" && "${GATEWAY_ID}" != "null" && -n "${GATEWAY_ID}" ]]; then
  GATEWAY_ARN=$(aws bedrock-agentcore-control get-gateway ${AWS_PROFILE_ARG} --region "${REGION}" \
    --gateway-identifier "${GATEWAY_ID}" --query "gatewayArn" --output text 2>/dev/null || echo "None")

  if [[ "${GATEWAY_ARN}" != "None" && -n "${GATEWAY_ARN}" ]]; then
    GW_LOG_GROUP="/aws/vendedlogs/bedrock-agentcore/gateway/APPLICATION_LOGS/${GATEWAY_ID}"

    aws logs create-log-group ${AWS_PROFILE_ARG} --region "${REGION}" \
      --log-group-name "${GW_LOG_GROUP}" 2>/dev/null || true

    aws logs put-delivery-source ${AWS_PROFILE_ARG} --region "${REGION}" \
      --name "${GATEWAY_ID}-logs-source" --log-type "APPLICATION_LOGS" \
      --resource-arn "${GATEWAY_ARN}" 2>/dev/null || true

    aws logs put-delivery-source ${AWS_PROFILE_ARG} --region "${REGION}" \
      --name "${GATEWAY_ID}-traces-source" --log-type "TRACES" \
      --resource-arn "${GATEWAY_ARN}" 2>/dev/null || true

    GW_LOG_GROUP_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${GW_LOG_GROUP}"
    LOGS_DEST_ARN=$(aws logs put-delivery-destination ${AWS_PROFILE_ARG} --region "${REGION}" \
      --name "${GATEWAY_ID}-logs-destination" --delivery-destination-type "CWL" \
      --delivery-destination-configuration "{\"destinationResourceArn\":\"${GW_LOG_GROUP_ARN}\"}" \
      --query 'deliveryDestination.arn' --output text 2>/dev/null || echo "")

    TRACES_DEST_ARN=$(aws logs put-delivery-destination ${AWS_PROFILE_ARG} --region "${REGION}" \
      --name "${GATEWAY_ID}-traces-destination" --delivery-destination-type "XRAY" \
      --query 'deliveryDestination.arn' --output text 2>/dev/null || echo "")

    if [[ -n "${LOGS_DEST_ARN}" ]]; then
      aws logs create-delivery ${AWS_PROFILE_ARG} --region "${REGION}" \
        --delivery-source-name "${GATEWAY_ID}-logs-source" \
        --delivery-destination-arn "${LOGS_DEST_ARN}" 2>/dev/null || true
    fi
    if [[ -n "${TRACES_DEST_ARN}" ]]; then
      aws logs create-delivery ${AWS_PROFILE_ARG} --region "${REGION}" \
        --delivery-source-name "${GATEWAY_ID}-traces-source" \
        --delivery-destination-arn "${TRACES_DEST_ARN}" 2>/dev/null || true
    fi

    echo "  Gateway observability enabled: ${GATEWAY_ID}"
  else
    echo "  WARNING: Could not get gateway ARN."
  fi
else
  echo "  WARNING: Could not find gateway."
fi
echo ""

# ─── Enable Runtime Tracing ───────────────────────────────────────────────────
echo "  Enabling Runtime tracing..."

RUNTIME_ARN=$(aws bedrock-agentcore-control list-agent-runtimes ${AWS_PROFILE_ARG} --region "${REGION}" \
  --query "agentRuntimes[?contains(agentRuntimeName,'${AGENT_NAME}')].agentRuntimeArn | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "${RUNTIME_ARN}" != "None" && "${RUNTIME_ARN}" != "null" && -n "${RUNTIME_ARN}" ]]; then
  RUNTIME_ID=$(echo "${RUNTIME_ARN}" | awk -F'/' '{print $NF}')

  # Create trace delivery source for the runtime
  aws logs put-delivery-source ${AWS_PROFILE_ARG} --region "${REGION}" \
    --name "${RUNTIME_ID}-traces-source" --log-type "TRACES" \
    --resource-arn "${RUNTIME_ARN}" 2>/dev/null || true

  RT_TRACES_DEST_ARN=$(aws logs put-delivery-destination ${AWS_PROFILE_ARG} --region "${REGION}" \
    --name "${RUNTIME_ID}-traces-destination" --delivery-destination-type "XRAY" \
    --query 'deliveryDestination.arn' --output text 2>/dev/null || echo "")

  if [[ -n "${RT_TRACES_DEST_ARN}" ]]; then
    aws logs create-delivery ${AWS_PROFILE_ARG} --region "${REGION}" \
      --delivery-source-name "${RUNTIME_ID}-traces-source" \
      --delivery-destination-arn "${RT_TRACES_DEST_ARN}" 2>/dev/null || true
  fi

  echo "  Runtime tracing enabled: ${RUNTIME_ID}"
else
  echo "  WARNING: Could not find runtime ARN for tracing."
fi
echo ""

# ─── Enable Memory Observability ──────────────────────────────────────────────
echo "  Enabling Memory observability..."

MEMORY_ARN=$(aws bedrock-agentcore-control list-memories ${AWS_PROFILE_ARG} --region "${REGION}" \
  --query "memories[?contains(arn,'${AGENT_NAME}')].arn | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "${MEMORY_ARN}" != "None" && "${MEMORY_ARN}" != "null" && -n "${MEMORY_ARN}" ]]; then
  MEMORY_ID=$(echo "${MEMORY_ARN}" | awk -F'/' '{print $NF}')
  MEM_LOG_GROUP="/aws/vendedlogs/bedrock-agentcore/memory/APPLICATION_LOGS/${MEMORY_ID}"

  aws logs create-log-group ${AWS_PROFILE_ARG} --region "${REGION}" \
    --log-group-name "${MEM_LOG_GROUP}" 2>/dev/null || true

  aws logs put-delivery-source ${AWS_PROFILE_ARG} --region "${REGION}" \
    --name "${MEMORY_ID}-logs-source" --log-type "APPLICATION_LOGS" \
    --resource-arn "${MEMORY_ARN}" 2>/dev/null || true

  aws logs put-delivery-source ${AWS_PROFILE_ARG} --region "${REGION}" \
    --name "${MEMORY_ID}-traces-source" --log-type "TRACES" \
    --resource-arn "${MEMORY_ARN}" 2>/dev/null || true

  MEM_LOG_GROUP_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${MEM_LOG_GROUP}"
  MEM_LOGS_DEST_ARN=$(aws logs put-delivery-destination ${AWS_PROFILE_ARG} --region "${REGION}" \
    --name "${MEMORY_ID}-logs-destination" --delivery-destination-type "CWL" \
    --delivery-destination-configuration "{\"destinationResourceArn\":\"${MEM_LOG_GROUP_ARN}\"}" \
    --query 'deliveryDestination.arn' --output text 2>/dev/null || echo "")

  MEM_TRACES_DEST_ARN=$(aws logs put-delivery-destination ${AWS_PROFILE_ARG} --region "${REGION}" \
    --name "${MEMORY_ID}-traces-destination" --delivery-destination-type "XRAY" \
    --query 'deliveryDestination.arn' --output text 2>/dev/null || echo "")

  if [[ -n "${MEM_LOGS_DEST_ARN}" ]]; then
    aws logs create-delivery ${AWS_PROFILE_ARG} --region "${REGION}" \
      --delivery-source-name "${MEMORY_ID}-logs-source" \
      --delivery-destination-arn "${MEM_LOGS_DEST_ARN}" 2>/dev/null || true
  fi
  if [[ -n "${MEM_TRACES_DEST_ARN}" ]]; then
    aws logs create-delivery ${AWS_PROFILE_ARG} --region "${REGION}" \
      --delivery-source-name "${MEMORY_ID}-traces-source" \
      --delivery-destination-arn "${MEM_TRACES_DEST_ARN}" 2>/dev/null || true
  fi

  echo "  Memory observability enabled: ${MEMORY_ID}"
else
  echo "  WARNING: Could not find memory ARN."
fi
echo ""

# ─── Grant IAM for the managed Web Search connector ──────────────────────────
# The web-search connector needs TWO IAM grants on TWO different identities.
# Both failures surface at SEARCH time (not deploy time), so we reconcile them
# explicitly here rather than trusting the CLI to have wired them:
#
#   1. OUTBOUND — the Gateway execution role must hold
#        bedrock-agentcore:InvokeWebSearch  on  arn:aws:bedrock-agentcore:us-east-1:aws:tool/web-search.v1
#      Missing it => tools/list works but every search fails with JSON-RPC -32002
#      "Execution role is not authorized for connector web-search".
#
#   2. INBOUND — the Runtime execution role (the caller that SigV4-signs the
#      gateway MCP request) must hold
#        bedrock-agentcore:InvokeGateway  on  the gateway ARN.
#      Missing it => the agent's calls to the gateway are refused.
#
# Note: the web-search tool resource is owned by AWS (account position = "aws").
# put-role-policy is idempotent, so this is safe whether or not the CLI already
# granted these.
echo "  Reconciling IAM for Web Search connector..."

WEBSEARCH_TOOL_ARN="arn:aws:bedrock-agentcore:us-east-1:aws:tool/web-search.v1"

# --- Outbound: InvokeWebSearch on the gateway execution role ---
if [[ "${GATEWAY_ID}" != "None" && "${GATEWAY_ID}" != "null" && -n "${GATEWAY_ID}" ]]; then
  GW_ROLE_ARN=$(aws bedrock-agentcore-control get-gateway ${AWS_PROFILE_ARG} --region "${REGION}" \
    --gateway-identifier "${GATEWAY_ID}" --query "roleArn" --output text 2>/dev/null || echo "None")

  if [[ "${GW_ROLE_ARN}" != "None" && "${GW_ROLE_ARN}" != "null" && -n "${GW_ROLE_ARN}" ]]; then
    GW_ROLE_NAME=$(echo "${GW_ROLE_ARN}" | awk -F'/' '{print $NF}')
    aws iam put-role-policy ${AWS_PROFILE_ARG} \
      --role-name "${GW_ROLE_NAME}" \
      --policy-name "AgentCoreWebSearchInvoke" \
      --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"InvokeWebSearch\",\"Effect\":\"Allow\",\"Action\":\"bedrock-agentcore:InvokeWebSearch\",\"Resource\":\"${WEBSEARCH_TOOL_ARN}\"}]}" \
      2>/dev/null \
      && echo "    Granted InvokeWebSearch to gateway role: ${GW_ROLE_NAME}" \
      || echo "    WARNING: could not attach InvokeWebSearch to ${GW_ROLE_NAME} (check IAM permissions)."
  else
    echo "    WARNING: could not resolve gateway execution role; web search will fail at call time."
  fi
else
  echo "    WARNING: gateway not found; skipping InvokeWebSearch grant."
fi

# --- Inbound: InvokeGateway on the runtime execution role (the caller) ---
RT_ARN_FOR_IAM=$(aws bedrock-agentcore-control list-agent-runtimes ${AWS_PROFILE_ARG} --region "${REGION}" \
  --query "agentRuntimes[?contains(agentRuntimeName,'${AGENT_NAME}')].agentRuntimeArn | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "${RT_ARN_FOR_IAM}" != "None" && "${RT_ARN_FOR_IAM}" != "null" && -n "${RT_ARN_FOR_IAM}" ]]; then
  RT_ID_FOR_IAM=$(echo "${RT_ARN_FOR_IAM}" | awk -F'/' '{print $NF}')
  RT_ROLE_ARN=$(aws bedrock-agentcore-control get-agent-runtime ${AWS_PROFILE_ARG} --region "${REGION}" \
    --agent-runtime-id "${RT_ID_FOR_IAM}" --query "roleArn" --output text 2>/dev/null || echo "None")

  if [[ "${RT_ROLE_ARN}" != "None" && "${RT_ROLE_ARN}" != "null" && -n "${RT_ROLE_ARN}" ]]; then
    RT_ROLE_NAME=$(echo "${RT_ROLE_ARN}" | awk -F'/' '{print $NF}')
    GATEWAY_ARN_FOR_IAM="${GATEWAY_ARN:-arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:gateway/${GATEWAY_ID}}"
    aws iam put-role-policy ${AWS_PROFILE_ARG} \
      --role-name "${RT_ROLE_NAME}" \
      --policy-name "AgentCoreInvokeGateway" \
      --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"InvokeGateway\",\"Effect\":\"Allow\",\"Action\":\"bedrock-agentcore:InvokeGateway\",\"Resource\":\"${GATEWAY_ARN_FOR_IAM}\"}]}" \
      2>/dev/null \
      && echo "    Granted InvokeGateway to runtime role: ${RT_ROLE_NAME}" \
      || echo "    WARNING: could not attach InvokeGateway to ${RT_ROLE_NAME} (check IAM permissions)."
  else
    echo "    WARNING: could not resolve runtime execution role; gateway calls may be refused."
  fi
else
  echo "    WARNING: runtime not found; skipping InvokeGateway grant."
fi
echo ""

# ─── Wire Gateway MCP into agent code + redeploy ─────────────────────────────
# The Gateway is now live (created during step [6/7] deploy). We look up its MCP
# endpoint URL and patch the agent code so tool calls route through the Gateway.
# This requires a second deploy — the Gateway ID isn't known until after the first
# deploy because `agentcore add gateway` only writes local config; the server-side
# resource is created by `agentcore deploy`.
echo "[7/7+] Wiring Gateway MCP endpoint into agent code..."

if [[ "${GATEWAY_ID}" != "None" && "${GATEWAY_ID}" != "null" && -n "${GATEWAY_ID}" ]]; then
  # Get the gateway endpoint URL from the get-gateway response
  GATEWAY_ENDPOINT=$(aws bedrock-agentcore-control get-gateway ${AWS_PROFILE_ARG} --region "${REGION}" \
    --gateway-identifier "${GATEWAY_ID}" --query "endpoint" --output text 2>/dev/null || echo "")

  if [[ -n "${GATEWAY_ENDPOINT}" && "${GATEWAY_ENDPOINT}" != "None" ]]; then
    GATEWAY_MCP_URL="${GATEWAY_ENDPOINT}/mcp"
  else
    # Fallback: construct from the gateway ID using the known URL pattern
    GATEWAY_MCP_URL="https://${GATEWAY_ID}.gateway.bedrock-agentcore.${REGION}.amazonaws.com/mcp"
  fi

  echo "  Gateway MCP URL: ${GATEWAY_MCP_URL}"

  # Create the mcp_client package directory
  MCP_CLIENT_DIR="${APP_DIR}/mcp_client"
  mkdir -p "${MCP_CLIENT_DIR}"

  # Write mcp_client/__init__.py
  cat > "${MCP_CLIENT_DIR}/__init__.py" << 'INITEOF'
INITEOF

  # Write mcp_client/client.py — connects to the AgentCore Gateway via SigV4
  cat > "${MCP_CLIENT_DIR}/client.py" << MCPEOF
import os
import logging
from mcp_proxy_for_aws.client import aws_iam_streamablehttp_client
from strands.tools.mcp.mcp_client import MCPClient

logger = logging.getLogger(__name__)

# Connects to the AgentCore Gateway, NOT directly to individual MCP servers.
# The gateway aggregates all targets (web-search, aws-knowledge-mcp, etc.) behind
# one MCP endpoint. Adding/removing gateway targets doesn't require agent code changes.
GATEWAY_URL = os.environ.get(
    "MCP_GATEWAY_URL",
    "${GATEWAY_MCP_URL}",
)
AWS_REGION = os.environ.get("AWS_REGION", "${REGION}")


def get_streamable_http_mcp_client() -> MCPClient:
    """Returns an MCP Client authenticated against the AgentCore Gateway via SigV4."""
    return MCPClient(lambda: aws_iam_streamablehttp_client(
        endpoint=GATEWAY_URL,
        aws_service="bedrock-agentcore",
        aws_region=AWS_REGION,
    ))
MCPEOF

  echo "  Created mcp_client/client.py with Gateway endpoint."

  # Rewrite main.py to import and use the Gateway-routed MCP client
  cat > "${APP_DIR}/main.py" << MAINEOF
from typing import Any
from collections import OrderedDict
from strands import Agent, tool
import asyncio
from strands.agent.conversation_manager.null_conversation_manager import NullConversationManager
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from model.load import load_model
from mcp_client.client import get_streamable_http_mcp_client

app = BedrockAgentCoreApp()
log = app.logger

# Define a Streamable HTTP MCP Client connected to the AgentCore Gateway
mcp_clients = [get_streamable_http_mcp_client()]

DEFAULT_SYSTEM_PROMPT = """${SYSTEM_PROMPT}"""


# Define a collection of tools used by the model
tools = []

_INLINE_FUNCTION_NAMES = set()

# Add MCP client to tools if available
for mcp_client in mcp_clients:
    if mcp_client:
        tools.append(mcp_client)


def _make_conversation_manager():
    return NullConversationManager()


def agent_factory():
    cache = OrderedDict()
    def get_or_create_agent(session_id):
        if session_id in cache:
            cache.move_to_end(session_id)
            return cache[session_id]
        if len(cache) >= 128:
            cache.popitem(last=False)
        cache[session_id] = Agent(
            model=load_model(),
            system_prompt=DEFAULT_SYSTEM_PROMPT,
            tools=tools,
            conversation_manager=_make_conversation_manager(),
        )
        return cache[session_id]
    return get_or_create_agent
get_or_create_agent = agent_factory()


def _extract_prompt(payload: dict):
    """Accept harness-style messages[], tool_results[], or plain prompt string payloads."""
    if "messages" in payload:
        return payload["messages"]
    if "tool_results" in payload:
        return [{"role": "user", "content": [{"toolResult": {
            "toolUseId": tr["toolUseId"],
            "status": tr.get("status", "success"),
            "content": tr.get("content", []),
        }} for tr in payload["tool_results"]]}]
    return payload.get("prompt", "")


@app.entrypoint
async def invoke(payload, context):
    log.info("Invoking Agent.....")

    session_id = getattr(context, 'session_id', 'default-session')
    agent = get_or_create_agent(session_id)

    prompt = _extract_prompt(payload)

    async for event in agent.stream_async(
        prompt,
    ):
        if not isinstance(event, dict) or "event" not in event:
            continue
        cbs = event["event"].get("contentBlockStart")
        if cbs is not None and not cbs.get("start"):
            continue
        yield event


if __name__ == "__main__":
    app.run()
MAINEOF

  echo "  Rewrote main.py with Gateway-routed MCP tool loading."

  # Ensure model/load.py uses the correct model_id
  mkdir -p "${APP_DIR}/model"
  cat > "${APP_DIR}/model/__init__.py" << 'MODELINITEOF'
MODELINITEOF

  cat > "${APP_DIR}/model/load.py" << MODELEOF
from strands.models.bedrock import BedrockModel


def load_model() -> BedrockModel:
    """Get Bedrock model client using IAM credentials."""
    return BedrockModel(model_id="${MODEL_ID}")
MODELEOF

  echo "  Updated model/load.py with model_id=${MODEL_ID}"

  # Ensure pyproject.toml includes the mcp-proxy-for-aws dependency
  if [[ -f "${APP_DIR}/pyproject.toml" ]]; then
    if ! grep -q "mcp-proxy-for-aws" "${APP_DIR}/pyproject.toml"; then
      python3 << DEPEOF
import re
toml_path = "${APP_DIR}/pyproject.toml"
with open(toml_path) as f:
    content = f.read()
# Add mcp-proxy-for-aws to dependencies if not present
if "mcp-proxy-for-aws" not in content:
    content = content.replace(
        '"strands-agents >= 1.15.0",',
        '"strands-agents >= 1.15.0",\n    "mcp-proxy-for-aws>=1.6.4",\n    "mcp ~= 1.24.0",'
    )
    with open(toml_path, 'w') as f:
        f.write(content)
    print("  Added mcp-proxy-for-aws to pyproject.toml")
DEPEOF
    else
      echo "  mcp-proxy-for-aws already in pyproject.toml"
    fi
  fi

  # Redeploy with the Gateway-wired code
  echo "  Redeploying with Gateway-routed agent code..."
  cd "${DEPLOY_DIR}"
  agentcore deploy -y -v
  echo "  Redeploy complete. Tool calls now route through Gateway."
else
  echo "  WARNING: Gateway ID not available — skipping MCP wiring."
  echo "  Tool calls will NOT route through Gateway (gateway_tool_call_count will be 0)."
fi
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "=============================================="
echo " Provisioning Complete!"
echo "=============================================="
echo ""
echo "Resources deployed:"
echo "  Agent (Runtime): ${AGENT_NAME} (Strands + CodeZip)"
echo "  Model:           ${MODEL_ID}"
echo "  Memory:          ${AGENT_NAME}_memory (SEMANTIC + SUMMARIZATION)"
echo "  Gateway:         ${GW_NAME} (web-search, aws-knowledge-mcp)"
echo ""
echo "  Region:          ${REGION}"
echo "  Account:         ${ACCOUNT_ID}"
echo "  Deploy Dir:      ${DEPLOY_DIR}"
echo ""
echo "Invoke:"
echo "  cd ${DEPLOY_DIR}"
echo "  agentcore invoke \"What are the latest AWS announcements?\" --stream"
echo ""
echo "Logs & Traces:"
echo "  agentcore logs"
echo "  agentcore traces list"
echo ""
echo "Cleanup:"
echo "  cd ${DEPLOY_DIR} && agentcore remove all -y && agentcore deploy -y"
echo "  rm -rf ${DEPLOY_DIR}"
echo ""
