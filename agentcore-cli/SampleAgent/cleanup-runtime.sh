#!/usr/bin/env bash
# cleanup-runtime.sh — Remove all resources created by provision-runtime.sh.
#
# Cleans up (reverse dependency order):
#   1. Observability (delivery sources, destinations, deliveries, log groups)
#   2. Gateway targets + gateway
#   3. Memory
#   4. Runtime agent (via agentcore CLI or direct API)
#   5. CloudFormation stack (if still exists)
#   6. Local deploy directory
#
# NOTE: Evaluation resources (custom evaluators, batch jobs) are shared across agents
# in an account and are NOT created by provisioning, so this per-agent cleanup does
# not touch them. To remove evaluators, run: ./cleanup-evaluators.sh --profile <profile>
#
# Usage:
#   ./cleanup-runtime.sh
#   ./cleanup-runtime.sh --name TeamAlpha --region us-east-1
#   ./cleanup-runtime.sh --name TeamAlpha --profile team-alpha --region eu-west-1
#
set -euo pipefail

export AGENTCORE_SUPPRESS_RECOMMENDATION=1

# ─── Script directory ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ────────────────────────────────────────────────────────────────
AGENT_NAME="HackathonAgent"
REGION="us-east-1"
AWS_PROFILE_ARG=""
KEEP_LOCAL="false"

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --name) AGENT_NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --profile) AWS_PROFILE_ARG="--profile $2"; export AWS_PROFILE="$2"; shift 2 ;;
    --keep-local) KEEP_LOCAL="true"; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Remove all AgentCore Runtime resources created by provision-runtime.sh."
      echo ""
      echo "Options:"
      echo "  --name NAME          Agent/project name (default: HackathonAgent)"
      echo "  --region REGION      AWS region (default: us-east-1)"
      echo "  --profile PROFILE    AWS CLI profile to use"
      echo "  --keep-local         Keep local deploy directory (don't delete files)"
      echo "  -h, --help           Show this help"
      echo ""
      echo "Examples:"
      echo "  ./cleanup-runtime.sh --name TeamAlpha --region us-east-1 --profile team-alpha"
      echo "  ./cleanup-runtime.sh --name TeamBeta --region eu-west-1 --profile team-beta"
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1"; exit 1 ;;
  esac
done

# Export region
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"

DEPLOY_DIR="${SCRIPT_DIR}/deploy-rt-${AGENT_NAME}"
GW_NAME="${AGENT_NAME}-gateway"

# ─── Validate AWS credentials ────────────────────────────────────────────────
echo "=============================================="
echo " AgentCore Runtime Cleanup"
echo "=============================================="
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity ${AWS_PROFILE_ARG} --query Account --output text --region "${REGION}") || {
  echo "ERROR: Cannot determine AWS account. Check your AWS credentials/profile and try again."
  exit 1
}

echo "  Agent:   ${AGENT_NAME}"
echo "  Region:  ${REGION}"
echo "  Account: ${ACCOUNT_ID}"
echo "  Profile: ${AWS_PROFILE:-default}"
echo ""

# ─── [1/6] Delete Observability (deliveries, destinations, sources, log groups) ─
echo "[1/6] Removing Observability resources (deliveries, sources, destinations, log groups)..."

# Helper function to delete a delivery by source name
delete_delivery_chain() {
  local SOURCE_NAME="$1"
  local DEST_NAME="$2"

  # Find and delete the delivery linking source to destination
  DELIVERY_ID=$(aws logs describe-deliveries ${AWS_PROFILE_ARG} --region "${REGION}" \
    --query "deliveries[?deliverySourceName=='${SOURCE_NAME}'].id | [0]" \
    --output text 2>/dev/null || echo "None")

  if [[ "${DELIVERY_ID}" != "None" && "${DELIVERY_ID}" != "null" && -n "${DELIVERY_ID}" ]]; then
    aws logs delete-delivery ${AWS_PROFILE_ARG} --region "${REGION}" \
      --id "${DELIVERY_ID}" 2>/dev/null || true
    echo "    Deleted delivery: ${DELIVERY_ID}"
  fi

  # Delete source
  aws logs delete-delivery-source ${AWS_PROFILE_ARG} --region "${REGION}" \
    --name "${SOURCE_NAME}" 2>/dev/null || true

  # Delete destination
  aws logs delete-delivery-destination ${AWS_PROFILE_ARG} --region "${REGION}" \
    --name "${DEST_NAME}" 2>/dev/null || true
}

# Gateway observability
GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways ${AWS_PROFILE_ARG} --region "${REGION}" \
  --query "items[?contains(name,'${GW_NAME}')].gatewayId | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "${GATEWAY_ID}" != "None" && "${GATEWAY_ID}" != "null" && -n "${GATEWAY_ID}" ]]; then
  echo "  Removing gateway observability (${GATEWAY_ID})..."
  delete_delivery_chain "${GATEWAY_ID}-logs-source" "${GATEWAY_ID}-logs-destination"
  delete_delivery_chain "${GATEWAY_ID}-traces-source" "${GATEWAY_ID}-traces-destination"

  GW_LOG_GROUP="/aws/vendedlogs/bedrock-agentcore/gateway/APPLICATION_LOGS/${GATEWAY_ID}"
  aws logs delete-log-group ${AWS_PROFILE_ARG} --region "${REGION}" \
    --log-group-name "${GW_LOG_GROUP}" 2>/dev/null || true
  echo "    Removed gateway log group: ${GW_LOG_GROUP}"
else
  echo "  No gateway found for observability cleanup."
fi

# Runtime observability
RUNTIME_ARN=$(aws bedrock-agentcore-control list-agent-runtimes ${AWS_PROFILE_ARG} --region "${REGION}" \
  --query "agentRuntimes[?contains(agentRuntimeName,'${AGENT_NAME}')].agentRuntimeArn | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "${RUNTIME_ARN}" != "None" && "${RUNTIME_ARN}" != "null" && -n "${RUNTIME_ARN}" ]]; then
  RUNTIME_ID=$(echo "${RUNTIME_ARN}" | awk -F'/' '{print $NF}')
  echo "  Removing runtime observability (${RUNTIME_ID})..."
  delete_delivery_chain "${RUNTIME_ID}-traces-source" "${RUNTIME_ID}-traces-destination"

  RT_LOG_GROUP="/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}-DEFAULT"
  aws logs delete-log-group ${AWS_PROFILE_ARG} --region "${REGION}" \
    --log-group-name "${RT_LOG_GROUP}" 2>/dev/null || true
  echo "    Removed runtime log group: ${RT_LOG_GROUP}"
else
  echo "  No runtime found for observability cleanup."
fi

# Memory observability
MEMORY_ARN=$(aws bedrock-agentcore-control list-memories ${AWS_PROFILE_ARG} --region "${REGION}" \
  --query "memories[?contains(arn,'${AGENT_NAME}')].arn | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "${MEMORY_ARN}" != "None" && "${MEMORY_ARN}" != "null" && -n "${MEMORY_ARN}" ]]; then
  MEMORY_ID=$(echo "${MEMORY_ARN}" | awk -F'/' '{print $NF}')
  echo "  Removing memory observability (${MEMORY_ID})..."
  delete_delivery_chain "${MEMORY_ID}-logs-source" "${MEMORY_ID}-logs-destination"
  delete_delivery_chain "${MEMORY_ID}-traces-source" "${MEMORY_ID}-traces-destination"

  MEM_LOG_GROUP="/aws/vendedlogs/bedrock-agentcore/memory/APPLICATION_LOGS/${MEMORY_ID}"
  aws logs delete-log-group ${AWS_PROFILE_ARG} --region "${REGION}" \
    --log-group-name "${MEM_LOG_GROUP}" 2>/dev/null || true
  echo "    Removed memory log group: ${MEM_LOG_GROUP}"
else
  echo "  No memory found for observability cleanup."
fi
echo ""

# ─── [2/6] Delete Gateway Targets and Gateway ────────────────────────────────
echo "[2/6] Removing Gateway and targets..."

if [[ "${GATEWAY_ID}" != "None" && "${GATEWAY_ID}" != "null" && -n "${GATEWAY_ID}" ]]; then
  echo "  Found gateway: ${GATEWAY_ID}"

  # Delete all gateway targets first
  TARGET_IDS=$(aws bedrock-agentcore-control list-gateway-targets ${AWS_PROFILE_ARG} \
    --gateway-identifier "${GATEWAY_ID}" --region "${REGION}" \
    --query 'targets[].targetId' --output text 2>/dev/null || echo "")

  for TID in ${TARGET_IDS}; do
    echo "  Deleting gateway target: ${TID}"
    aws bedrock-agentcore-control delete-gateway-target ${AWS_PROFILE_ARG} \
      --gateway-identifier "${GATEWAY_ID}" --target-identifier "${TID}" \
      --region "${REGION}" 2>/dev/null || echo "    WARNING: Failed to delete target ${TID}"
  done

  # Wait for targets to be removed
  if [[ -n "${TARGET_IDS}" ]]; then
    echo "  Waiting for targets to be deleted..."
    sleep 5
  fi

  # Delete the gateway
  echo "  Deleting gateway: ${GW_NAME}"
  aws bedrock-agentcore-control delete-gateway ${AWS_PROFILE_ARG} \
    --gateway-identifier "${GATEWAY_ID}" \
    --region "${REGION}" 2>/dev/null || echo "  WARNING: Failed to delete gateway"
  echo "  Gateway deleted."
else
  echo "  No gateway found matching: ${GW_NAME} (skipping)"
fi
echo ""

# ─── [3/6] Delete Memory ─────────────────────────────────────────────────────
echo "[3/6] Removing Memory..."

if [[ "${MEMORY_ARN}" != "None" && "${MEMORY_ARN}" != "null" && -n "${MEMORY_ARN}" ]]; then
  MEMORY_ID=$(echo "${MEMORY_ARN}" | awk -F'/' '{print $NF}')
  echo "  Deleting memory: ${MEMORY_ID}"
  aws bedrock-agentcore-control delete-memory ${AWS_PROFILE_ARG} \
    --memory-id "${MEMORY_ID}" \
    --region "${REGION}" 2>/dev/null || echo "  WARNING: Failed to delete memory"
  echo "  Memory deleted."
else
  echo "  No memory found matching: ${AGENT_NAME} (skipping)"
fi
echo ""

# ─── [4/6] Remove Runtime via AgentCore CLI or direct API ─────────────────────
echo "[4/6] Removing Runtime agent and infrastructure..."

if [[ -d "${DEPLOY_DIR}" ]]; then
  cd "${DEPLOY_DIR}"

  # Use agentcore remove all to tear down everything managed by the CLI
  echo "  Running: agentcore remove all"
  agentcore remove all 2>/dev/null || echo "  WARNING: agentcore remove all returned non-zero"

  echo "  Deploying empty config to tear down AWS resources..."
  agentcore deploy -y 2>/dev/null || echo "  WARNING: agentcore deploy (teardown) returned non-zero"

  echo "  AgentCore resources removed via CLI."
  cd "${SCRIPT_DIR}"
else
  echo "  No local deploy directory found: ${DEPLOY_DIR}"
  echo "  Attempting direct API cleanup..."

  # Fallback: delete runtime directly via AWS CLI
  if [[ "${RUNTIME_ARN}" != "None" && "${RUNTIME_ARN}" != "null" && -n "${RUNTIME_ARN}" ]]; then
    RUNTIME_ID=$(echo "${RUNTIME_ARN}" | awk -F'/' '{print $NF}')
    echo "  Deleting runtime: ${RUNTIME_ID}"
    aws bedrock-agentcore-control delete-agent-runtime ${AWS_PROFILE_ARG} \
      --agent-runtime-id "${RUNTIME_ID}" \
      --region "${REGION}" 2>/dev/null || echo "  WARNING: Failed to delete runtime"
  else
    # Try alternative naming patterns
    RUNTIME_NAMES=("${AGENT_NAME}_${AGENT_NAME}" "${AGENT_NAME}")
    for RUNTIME_NAME in "${RUNTIME_NAMES[@]}"; do
      RT_ID=$(aws bedrock-agentcore-control list-agent-runtimes ${AWS_PROFILE_ARG} --region "${REGION}" \
        --query "agentRuntimes[?starts_with(agentRuntimeName,'${RUNTIME_NAME}')].agentRuntimeId | [0]" \
        --output text 2>/dev/null || echo "None")

      if [[ "${RT_ID}" != "None" && "${RT_ID}" != "null" && -n "${RT_ID}" ]]; then
        echo "  Deleting runtime: ${RT_ID} (${RUNTIME_NAME})"
        aws bedrock-agentcore-control delete-agent-runtime ${AWS_PROFILE_ARG} \
          --agent-runtime-id "${RT_ID}" \
          --region "${REGION}" 2>/dev/null || echo "  WARNING: Failed to delete runtime"
        break
      fi
    done
  fi
fi
echo ""

# ─── [5/6] Delete CloudFormation stack (if still exists) ──────────────────────
echo "[5/6] Checking for remaining CloudFormation stacks..."

STACK_PATTERNS=("AgentCore-${AGENT_NAME}-default" "AgentCore-${AGENT_NAME}")
for STACK_NAME in "${STACK_PATTERNS[@]}"; do
  STACK_STATUS=$(aws cloudformation describe-stacks ${AWS_PROFILE_ARG} \
    --stack-name "${STACK_NAME}" --region "${REGION}" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "${STACK_STATUS}" != "NOT_FOUND" && "${STACK_STATUS}" != "DELETE_COMPLETE" ]]; then
    echo "  Deleting CloudFormation stack: ${STACK_NAME} (status: ${STACK_STATUS})"
    aws cloudformation delete-stack ${AWS_PROFILE_ARG} \
      --stack-name "${STACK_NAME}" --region "${REGION}" 2>/dev/null || echo "  WARNING: Failed to delete stack"

    echo "  Waiting for stack deletion..."
    aws cloudformation wait stack-delete-complete ${AWS_PROFILE_ARG} \
      --stack-name "${STACK_NAME}" --region "${REGION}" 2>/dev/null || echo "  WARNING: Stack deletion timed out"
    echo "  Stack deleted: ${STACK_NAME}"
  else
    echo "  No stack found: ${STACK_NAME} (skipping)"
  fi
done
echo ""

# ─── [6/6] Remove local deploy directory ─────────────────────────────────────
echo "[6/6] Cleaning up local files..."

if [[ "${KEEP_LOCAL}" == "true" ]]; then
  echo "  Keeping local directory: ${DEPLOY_DIR} (--keep-local)"
elif [[ -d "${DEPLOY_DIR}" ]]; then
  rm -rf "${DEPLOY_DIR}"
  echo "  Removed local directory: ${DEPLOY_DIR}"
else
  echo "  No local directory to remove."
fi
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "=============================================="
echo " Cleanup Complete"
echo "=============================================="
echo ""
echo "Removed resources:"
echo "  - Observability:  Gateway, Runtime, and Memory delivery pipelines"
echo "  - Gateway:        ${GW_NAME} (+ targets: exa-search, aws-knowledge-mcp)"
echo "  - Memory:         ${AGENT_NAME}_memory"
echo "  - Runtime:        ${AGENT_NAME}"
echo "  - Local files:    deploy-rt-${AGENT_NAME}/"
echo ""
echo "Verify nothing remains:"
echo "  aws bedrock-agentcore-control list-agent-runtimes ${AWS_PROFILE_ARG} --region ${REGION} \\"
echo "    --query \"agentRuntimes[].{Name:agentRuntimeName,Status:status}\" --output table"
echo ""
echo "  aws bedrock-agentcore-control list-gateways ${AWS_PROFILE_ARG} --region ${REGION} \\"
echo "    --query \"items[].{Name:name,Status:status}\" --output table"
echo ""
echo "  aws bedrock-agentcore-control list-memories ${AWS_PROFILE_ARG} --region ${REGION} \\"
echo "    --query \"memories[].{Name:name}\" --output table"
echo ""
