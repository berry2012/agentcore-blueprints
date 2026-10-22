#!/usr/bin/env bash
# provision-harness.sh — Deploy a Harness agent with gateway, MCP tools, and memory.
#
# Creates:
#   - An AgentCore Harness agent (Bedrock)
#   - Memory (SEMANTIC + SUMMARIZATION)
#   - Gateway with 2 MCP tool targets (EXA search + AWS MCP server)
#
# Usage:
#   ./provision-harness.sh
#   ./provision-harness.sh --profile my-aws-profile
#   ./provision-harness.sh --region us-west-2 --profile hackathon-team1
#   ./provision-harness.sh --name MyTeamAgent --region eu-west-1
#
set -euo pipefail

export AGENTCORE_SUPPRESS_RECOMMENDATION=1

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
EXA_API_KEY=""
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
    --exa-api-key) EXA_API_KEY="$2"; shift 2 ;;
    --system-prompt) SYSTEM_PROMPT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Provision an AgentCore Harness agent with gateway, MCP tools, and memory."
      echo ""
      echo "Options:"
      echo "  --name NAME                  Agent/project name (default: HackathonAgent)"
      echo "  --region REGION              AWS region (default: us-east-1)"
      echo "  --profile PROFILE            AWS CLI profile to use (isolates accounts)"
      echo "  --network-mode MODE          Network mode: PUBLIC or VPC (default: PUBLIC)"
      echo "  --subnets IDS                Comma-separated subnet IDs (required for VPC)"
      echo "  --security-groups IDS        Comma-separated security group IDs (required for VPC)"
      echo "  --model-id MODEL_ID          Bedrock model ID (default: auto-detected based on region)"
      echo "  --exa-api-key KEY            EXA API key (optional, for authenticated EXA access)"
      echo "  --system-prompt PROMPT       Custom system prompt for the harness"
      echo "  -h, --help                   Show this help"
      echo ""
      echo "Examples:"
      echo "  # Deploy with default settings"
      echo "  ./provision-harness.sh"
      echo ""
      echo "  # Deploy for a specific team account"
      echo "  ./provision-harness.sh --name TeamAlpha --profile team-alpha --region eu-west-1"
      echo ""
      echo "  # Deploy in VPC mode"
      echo "  ./provision-harness.sh --network-mode VPC --subnets subnet-abc --security-groups sg-123"
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
echo " AgentCore Harness Agent Provisioning"
echo "=============================================="
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity ${AWS_PROFILE_ARG} --query Account --output text --region "${REGION}") || {
  echo "ERROR: Cannot determine AWS account. Check your AWS credentials/profile and try again."
  exit 1
}

echo "  Agent:   ${AGENT_NAME}"
echo "  Region:  ${REGION}"
echo "  Account: ${ACCOUNT_ID}"
echo "  Model:   ${MODEL_ID}"
echo "  Profile: ${AWS_PROFILE:-default}"
echo ""

export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"

# ─── Deployment directory ─────────────────────────────────────────────────────
DEPLOY_DIR="${SCRIPT_DIR}/deploy-${AGENT_NAME}"

# ─── [1/6] Create Harness project ────────────────────────────────────────────
echo "[1/6] Creating Harness project: ${AGENT_NAME}..."

if [[ -d "${DEPLOY_DIR}" ]]; then
  echo "  Deploy directory already exists: ${DEPLOY_DIR}"
  echo "  Reusing existing project..."
else
  cd "${SCRIPT_DIR}"

  agentcore create \
    --name "${AGENT_NAME}" \
    --model-provider Bedrock

  mv "${AGENT_NAME}" "${DEPLOY_DIR}" 2>/dev/null || true
  echo "  Project created at: ${DEPLOY_DIR}"
fi

cd "${DEPLOY_DIR}"

# Update aws-targets.json
python3 -c "
import json
targets = [{'name': 'default', 'description': 'Hackathon deployment (${REGION})', 'account': '${ACCOUNT_ID}', 'region': '${REGION}'}]
with open('agentcore/aws-targets.json', 'w') as f:
    json.dump(targets, f, indent=2)
"
echo "  Set region=${REGION}, account=${ACCOUNT_ID} in aws-targets.json"
echo ""

# ─── [2/6] Configure Harness model and system prompt ─────────────────────────
echo "[2/6] Configuring Harness (model + system prompt)..."

cd "${DEPLOY_DIR}"

# The harness config lives in app/<name>/harness.json and system-prompt.md
HARNESS_JSON="${DEPLOY_DIR}/app/${AGENT_NAME}/harness.json"
SYSTEM_PROMPT_FILE="${DEPLOY_DIR}/app/${AGENT_NAME}/system-prompt.md"

# Update harness.json with correct model ID
if [[ -f "${HARNESS_JSON}" ]]; then
  python3 << PYUPDATE
import json
harness_file = "${HARNESS_JSON}"
with open(harness_file) as f:
    harness = json.load(f)
harness['model'] = {
    'provider': 'bedrock',
    'modelId': '${MODEL_ID}'
}
with open(harness_file, 'w') as f:
    json.dump(harness, f, indent=2)
PYUPDATE
  echo "  Model updated in harness.json: ${MODEL_ID}"
else
  echo "  WARNING: harness.json not found at ${HARNESS_JSON}"
fi

# Update system prompt
if [[ -f "${SYSTEM_PROMPT_FILE}" ]]; then
  python3 -c "
import sys
prompt = sys.argv[1]
with open(sys.argv[2], 'w') as f:
    f.write(prompt + '\n')
" "${SYSTEM_PROMPT}" "${SYSTEM_PROMPT_FILE}"
  echo "  System prompt updated in system-prompt.md"
else
  echo "  WARNING: system-prompt.md not found, creating..."
  python3 -c "
import sys
prompt = sys.argv[1]
with open(sys.argv[2], 'w') as f:
    f.write(prompt + '\n')
" "${SYSTEM_PROMPT}" "${SYSTEM_PROMPT_FILE}"
fi
echo ""

# ─── [3/6] Add Memory ────────────────────────────────────────────────────────
echo "[3/6] Adding Memory (SEMANTIC + SUMMARIZATION)..."

cd "${DEPLOY_DIR}"

# Check if memory already exists
HAS_MEMORY=$(python3 -c "
import json
with open('agentcore/agentcore.json') as f:
    config = json.load(f)
memories = config.get('memories', [])
print('yes' if memories else 'no')
" 2>/dev/null || echo "no")

if [[ "${HAS_MEMORY}" == "no" ]]; then
  agentcore add memory \
    --name "${AGENT_NAME}_memory" \
    --strategies SEMANTIC,SUMMARIZATION
  echo "  Memory added: ${AGENT_NAME}_memory (SEMANTIC + SUMMARIZATION)"
else
  echo "  Memory already configured, skipping."
fi
echo ""

# ─── [4/6] Create Gateway ────────────────────────────────────────────────────
echo "[4/6] Creating Gateway..."

cd "${DEPLOY_DIR}"

GW_NAME="${AGENT_NAME}-gateway"

HAS_GATEWAY=$(python3 -c "
import json
with open('agentcore/agentcore.json') as f:
    config = json.load(f)
gateways = config.get('agentCoreGateways', config.get('gateways', []))
print('yes' if gateways else 'no')
" 2>/dev/null || echo "no")

if [[ "${HAS_GATEWAY}" == "no" ]]; then
  agentcore add gateway \
    --name "${GW_NAME}" \
    --authorizer-type NONE
  echo "  Gateway created: ${GW_NAME} (no auth)"
else
  echo "  Gateway already configured, skipping."
fi
echo ""

# ─── [5/6] Add MCP Tool Targets to Gateway ───────────────────────────────────
echo "[5/6] Adding MCP tool targets (EXA + AWS MCP)..."

cd "${DEPLOY_DIR}"

# Target 1: EXA search MCP server
echo "  Adding EXA search MCP server..."
HAS_EXA=$(python3 -c "
import json
with open('agentcore/agentcore.json') as f:
    config = json.load(f)
for gw in config.get('agentCoreGateways', []):
    for t in gw.get('targets', []):
        if 'exa' in t.get('name', '').lower():
            print('yes')
            exit()
# Also check top-level gatewayTargets if present
for t in config.get('gatewayTargets', []):
    if 'exa' in t.get('name', '').lower():
        print('yes')
        exit()
print('no')
" 2>/dev/null || echo "no")

if [[ "${HAS_EXA}" == "no" ]]; then
  agentcore add gateway-target \
    --name "exa-search" \
    --type mcp-server \
    --endpoint "https://mcp.exa.ai/mcp" \
    --gateway "${GW_NAME}"
  echo "  EXA search target added -> https://mcp.exa.ai/mcp"
else
  echo "  EXA target already exists, skipping."
fi

# Target 2: AWS MCP server (documentation)
echo "  Adding AWS documentation MCP server..."
HAS_AWS_MCP=$(python3 -c "
import json
with open('agentcore/agentcore.json') as f:
    config = json.load(f)
for gw in config.get('agentCoreGateways', []):
    for t in gw.get('targets', []):
        if 'aws' in t.get('name', '').lower():
            print('yes')
            exit()
for t in config.get('gatewayTargets', []):
    if 'aws' in t.get('name', '').lower():
        print('yes')
        exit()
print('no')
" 2>/dev/null || echo "no")

if [[ "${HAS_AWS_MCP}" == "no" ]]; then
  agentcore add gateway-target \
    --name "aws-docs-mcp" \
    --type mcp-server \
    --endpoint "https://knowledge-mcp.global.api.aws" \
    --gateway "${GW_NAME}"
  echo "  AWS docs MCP target added -> https://knowledge-mcp.global.api.aws"
else
  echo "  AWS MCP target already exists, skipping."
fi
echo ""

# ─── [6/6] Gateway tool will be attached after first deploy ───────────────────
echo "[6/6] Gateway tool will be attached post-deploy (requires real gateway ARN)..."
echo "  Skipping for now — the gateway must be deployed first to get its ARN."
echo ""

# ─── Deploy Phase 1: Gateway + Memory + Harness (without gateway tool) ────────
echo "=============================================="
echo " Phase 1: Deploying gateway, memory, and harness..."
echo "=============================================="
echo ""

cd "${DEPLOY_DIR}"

# Enable CloudWatch Transaction Search (required for spans/traces to flow)
echo "  Ensuring CloudWatch Transaction Search is enabled..."
TXSEARCH_STATUS=$(aws observabilityadmin get-telemetry-evaluation-status ${AWS_PROFILE_ARG} --region "${REGION}" \
  --query "Status" --output text 2>/dev/null || echo "UNKNOWN")

if [[ "${TXSEARCH_STATUS}" == "NOT_STARTED" ]]; then
  aws observabilityadmin start-telemetry-evaluation ${AWS_PROFILE_ARG} --region "${REGION}" 2>/dev/null || true
  echo "  Transaction Search enabled (was NOT_STARTED)."
elif [[ "${TXSEARCH_STATUS}" == "RUNNING" ]]; then
  echo "  Transaction Search already enabled."
else
  echo "  Transaction Search status: ${TXSEARCH_STATUS} (proceeding anyway)"
fi
echo ""

# Remove any gateway tool with placeholder ARN from harness.json before deploying
python3 << PYSTRIP
import json
harness_file = '${DEPLOY_DIR}/app/${AGENT_NAME}/harness.json'
with open(harness_file) as f:
    harness = json.load(f)
# Remove gateway tools with placeholder ARN
harness['tools'] = [
    t for t in harness.get('tools', [])
    if not (t.get('type') == 'agentcore_gateway' and
            t.get('config', {}).get('agentCoreGateway', {}).get('gatewayArn', '') == 'placeholder')
]
with open(harness_file, 'w') as f:
    json.dump(harness, f, indent=2)
PYSTRIP

agentcore deploy -y -v

echo ""

# ─── Deploy Phase 2: Attach Gateway tool with real ARN ───────────────────────
echo "=============================================="
echo " Phase 2: Attaching Gateway to Harness..."
echo "=============================================="
echo ""

# Fetch the actual gateway ARN from the deployed resources
GATEWAY_ARN=$(aws bedrock-agentcore-control list-gateways ${AWS_PROFILE_ARG} --region "${REGION}" \
  --query "items[?contains(name,'${GW_NAME}')].gatewayArn | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "${GATEWAY_ARN}" != "None" && "${GATEWAY_ARN}" != "null" && -n "${GATEWAY_ARN}" ]]; then
  echo "  Gateway ARN: ${GATEWAY_ARN}"

  # Check if gateway tool is already properly configured
  HAS_GW_TOOL=$(python3 -c "
import json
harness_file = '${DEPLOY_DIR}/app/${AGENT_NAME}/harness.json'
with open(harness_file) as f:
    harness = json.load(f)
tools = harness.get('tools', [])
gw_tools = [t for t in tools if t.get('type') == 'agentcore_gateway'
             and t.get('config', {}).get('agentCoreGateway', {}).get('gatewayArn', '') != 'placeholder']
print('yes' if gw_tools else 'no')
" 2>/dev/null || echo "no")

  if [[ "${HAS_GW_TOOL}" == "no" ]]; then
    # Add the gateway tool with the real ARN
    agentcore add tool --harness "${AGENT_NAME}" --type agentcore_gateway \
      --name "${GW_NAME}" \
      --gateway-arn "${GATEWAY_ARN}"
    echo "  Gateway tool attached to harness with real ARN."

    # Re-deploy to apply
    echo "  Re-deploying with gateway tool..."
    agentcore deploy -y
  else
    echo "  Gateway tool already attached with valid ARN."
  fi
else
  echo "  WARNING: Could not resolve gateway ARN. The harness is deployed without gateway tools."
  echo "  You can manually attach it later:"
  echo "    cd ${DEPLOY_DIR}"
  echo "    agentcore add tool --harness ${AGENT_NAME} --type agentcore_gateway --name ${GW_NAME} --gateway-arn <ARN>"
  echo "    agentcore deploy -y"
fi

echo ""

# ─── Post-deploy: Enable Gateway Observability ────────────────────────────────
echo "=============================================="
echo " Post-deploy: Enabling Gateway Observability..."
echo "=============================================="
echo ""

if [[ "${GATEWAY_ARN}" != "None" && "${GATEWAY_ARN}" != "null" && -n "${GATEWAY_ARN}" ]]; then
  GATEWAY_ID=$(echo "${GATEWAY_ARN}" | awk -F'/' '{print $NF}')

  python3 << PYOBS
import boto3, sys

region = '${REGION}'
account_id = '${ACCOUNT_ID}'
gateway_arn = '${GATEWAY_ARN}'
gateway_id = '${GATEWAY_ID}'

session = boto3.Session(profile_name='${AWS_PROFILE:-}' or None, region_name=region)
logs_client = session.client('logs', region_name=region)

log_group_name = f'/aws/vendedlogs/bedrock-agentcore/gateway/APPLICATION_LOGS/{gateway_id}'

# Step 0: Create log group (ignore if exists)
try:
    logs_client.create_log_group(logGroupName=log_group_name)
    print(f'  Created log group: {log_group_name}')
except logs_client.exceptions.ResourceAlreadyExistsException:
    print(f'  Log group already exists: {log_group_name}')
except Exception as e:
    print(f'  WARNING: Could not create log group: {e}')

log_group_arn = f'arn:aws:logs:{region}:{account_id}:log-group:{log_group_name}'

# Step 1: Create delivery source for logs
try:
    logs_client.put_delivery_source(
        name=f'{gateway_id}-logs-source',
        logType='APPLICATION_LOGS',
        resourceArn=gateway_arn
    )
    print('  Created delivery source (logs)')
except Exception as e:
    if 'ConflictException' in str(type(e).__name__) or 'already exists' in str(e).lower():
        print('  Delivery source (logs) already exists')
    else:
        print(f'  WARNING: Could not create delivery source: {e}')

# Step 2: Create delivery source for traces
try:
    logs_client.put_delivery_source(
        name=f'{gateway_id}-traces-source',
        logType='TRACES',
        resourceArn=gateway_arn
    )
    print('  Created delivery source (traces)')
except Exception as e:
    if 'ConflictException' in str(type(e).__name__) or 'already exists' in str(e).lower():
        print('  Delivery source (traces) already exists')
    else:
        print(f'  WARNING: Could not create delivery source (traces): {e}')

# Step 3: Create delivery destination (CloudWatch Logs)
try:
    logs_dest = logs_client.put_delivery_destination(
        name=f'{gateway_id}-logs-destination',
        deliveryDestinationType='CWL',
        deliveryDestinationConfiguration={
            'destinationResourceArn': log_group_arn,
        }
    )
    logs_dest_arn = logs_dest['deliveryDestination']['arn']
    print('  Created delivery destination (logs -> CloudWatch)')
except Exception as e:
    if 'ConflictException' in str(type(e).__name__) or 'already exists' in str(e).lower():
        print('  Delivery destination (logs) already exists')
        # Get existing ARN
        try:
            existing = logs_client.get_delivery_destination(name=f'{gateway_id}-logs-destination')
            logs_dest_arn = existing['deliveryDestination']['arn']
        except:
            logs_dest_arn = None
    else:
        print(f'  WARNING: Could not create delivery destination: {e}')
        logs_dest_arn = None

# Step 4: Create delivery destination (X-Ray traces)
try:
    traces_dest = logs_client.put_delivery_destination(
        name=f'{gateway_id}-traces-destination',
        deliveryDestinationType='XRAY'
    )
    traces_dest_arn = traces_dest['deliveryDestination']['arn']
    print('  Created delivery destination (traces -> X-Ray)')
except Exception as e:
    if 'ConflictException' in str(type(e).__name__) or 'already exists' in str(e).lower():
        print('  Delivery destination (traces) already exists')
        try:
            existing = logs_client.get_delivery_destination(name=f'{gateway_id}-traces-destination')
            traces_dest_arn = existing['deliveryDestination']['arn']
        except:
            traces_dest_arn = None
    else:
        print(f'  WARNING: Could not create delivery destination (traces): {e}')
        traces_dest_arn = None

# Step 5: Create deliveries (connect sources to destinations)
if logs_dest_arn:
    try:
        logs_client.create_delivery(
            deliverySourceName=f'{gateway_id}-logs-source',
            deliveryDestinationArn=logs_dest_arn
        )
        print('  Created delivery: logs -> CloudWatch')
    except Exception as e:
        if 'ConflictException' in str(type(e).__name__) or 'already exists' in str(e).lower():
            print('  Delivery (logs) already exists')
        else:
            print(f'  WARNING: Could not create logs delivery: {e}')

if traces_dest_arn:
    try:
        logs_client.create_delivery(
            deliverySourceName=f'{gateway_id}-traces-source',
            deliveryDestinationArn=traces_dest_arn
        )
        print('  Created delivery: traces -> X-Ray')
    except Exception as e:
        if 'ConflictException' in str(type(e).__name__) or 'already exists' in str(e).lower():
            print('  Delivery (traces) already exists')
        else:
            print(f'  WARNING: Could not create traces delivery: {e}')

print('  Gateway observability enabled.')
PYOBS
else
  echo "  No gateway ARN available, skipping gateway observability."
fi

echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "=============================================="
echo " Provisioning Complete!"
echo "=============================================="
echo ""
echo "Resources deployed:"
echo "  Agent (Harness): ${AGENT_NAME}"
echo "  Model:           ${MODEL_ID}"
echo "  Memory:          ${AGENT_NAME}_memory (SEMANTIC + SUMMARIZATION)"
echo "  Gateway:         ${GW_NAME}"
echo "  MCP Targets:     exa-search, aws-docs-mcp"
echo ""
echo "  Region:          ${REGION}"
echo "  Account:         ${ACCOUNT_ID}"
echo "  Deploy Dir:      ${DEPLOY_DIR}"
echo ""
echo "Verify:"
echo "  agentcore status"
echo ""
echo "Invoke the agent:"
echo "  cd ${DEPLOY_DIR}"
echo "  agentcore invoke --harness ${AGENT_NAME} --session-id \"\$(uuidgen)\" \"What are the latest AWS announcements?\""
echo ""
echo "Stream logs:"
echo "  agentcore logs --harness ${AGENT_NAME}"
echo ""
echo "Cleanup:"
echo "  ${SCRIPT_DIR}/cleanup-harness.sh --name ${AGENT_NAME} --region ${REGION}${AWS_PROFILE:+ --profile ${AWS_PROFILE}}"
echo ""
