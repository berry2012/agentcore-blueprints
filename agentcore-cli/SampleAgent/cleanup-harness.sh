#!/usr/bin/env bash
# cleanup-harness.sh — Remove all resources created by provision-harness.sh.
#
# Cleans up (reverse dependency order):
#   1. Gateway targets + gateway
#   2. Memory
#   3. Harness agent (runtime + CDK stack)
#   4. Local deploy directory
#
# NOTE: Evaluation resources (custom evaluators, batch jobs) are shared across agents
# in an account and are NOT created by provisioning, so this per-agent cleanup does
# not touch them. To remove evaluators, run: ./cleanup-evaluators.sh --profile <profile>
#
# Usage:
#   ./cleanup-harness.sh
#   ./cleanup-harness.sh --name HackathonAgent --region us-east-1
#   ./cleanup-harness.sh --name TeamAlpha --profile team-alpha --region eu-west-1
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
      echo "Remove all AgentCore Harness resources created by provision-harness.sh."
      echo ""
      echo "Options:"
      echo "  --name NAME          Agent/project name (default: HackathonAgent)"
      echo "  --region REGION      AWS region (default: us-east-1)"
      echo "  --profile PROFILE    AWS CLI profile to use"
      echo "  --keep-local         Keep local deploy directory (don't delete files)"
      echo "  -h, --help           Show this help"
      echo ""
      echo "Examples:"
      echo "  ./cleanup-harness.sh --name TeamAlpha --region eu-west-1 --profile team-alpha"
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1"; exit 1 ;;
  esac
done

# Export region
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"

DEPLOY_DIR="${SCRIPT_DIR}/deploy-${AGENT_NAME}"
GW_NAME="${AGENT_NAME}-gateway"

# ─── Validate AWS credentials ────────────────────────────────────────────────
echo "=============================================="
echo " AgentCore Harness Cleanup"
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

# ─── [1/4] Delete Gateway Targets and Gateway ────────────────────────────────
echo "[1/4] Removing Gateway and targets..."

GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways ${AWS_PROFILE_ARG} --region "${REGION}" \
  --query "items[?contains(name,'${GW_NAME}')].gatewayId | [0]" \
  --output text 2>/dev/null || echo "None")

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

# ─── [2/4] Remove via AgentCore CLI (handles harness, memory, CDK stack) ─────
echo "[2/4] Removing Harness agent, memory, and infrastructure..."

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
  RUNTIME_NAMES=("${AGENT_NAME}_${AGENT_NAME}" "${AGENT_NAME}")
  for RUNTIME_NAME in "${RUNTIME_NAMES[@]}"; do
    RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes ${AWS_PROFILE_ARG} --region "${REGION}" \
      --query "agentRuntimes[?starts_with(agentRuntimeName,'${RUNTIME_NAME}')].agentRuntimeId | [0]" \
      --output text 2>/dev/null || echo "None")

    if [[ "${RUNTIME_ID}" != "None" && "${RUNTIME_ID}" != "null" && -n "${RUNTIME_ID}" ]]; then
      echo "  Deleting runtime: ${RUNTIME_ID} (${RUNTIME_NAME})"
      aws bedrock-agentcore-control delete-agent-runtime ${AWS_PROFILE_ARG} \
        --agent-runtime-id "${RUNTIME_ID}" \
        --region "${REGION}" 2>/dev/null || echo "  WARNING: Failed to delete runtime"
      break
    fi
  done

  # Try to delete the harness
  HARNESS_ID=$(aws bedrock-agentcore-control list-harnesses ${AWS_PROFILE_ARG} --region "${REGION}" \
    --query "harnesses[?contains(name,'${AGENT_NAME}')].harnessId | [0]" \
    --output text 2>/dev/null || echo "None")

  if [[ "${HARNESS_ID}" != "None" && "${HARNESS_ID}" != "null" && -n "${HARNESS_ID}" ]]; then
    echo "  Deleting harness: ${HARNESS_ID}"
    aws bedrock-agentcore-control delete-harness ${AWS_PROFILE_ARG} \
      --harness-id "${HARNESS_ID}" \
      --region "${REGION}" 2>/dev/null || echo "  WARNING: Failed to delete harness"
  fi

  # Try to delete memory
  MEMORY_ID=$(aws bedrock-agentcore-control list-memories ${AWS_PROFILE_ARG} --region "${REGION}" \
    --query "memories[?contains(name,'${AGENT_NAME}')].memoryId | [0]" \
    --output text 2>/dev/null || echo "None")

  if [[ "${MEMORY_ID}" != "None" && "${MEMORY_ID}" != "null" && -n "${MEMORY_ID}" ]]; then
    echo "  Deleting memory: ${MEMORY_ID}"
    aws bedrock-agentcore-control delete-memory ${AWS_PROFILE_ARG} \
      --memory-id "${MEMORY_ID}" \
      --region "${REGION}" 2>/dev/null || echo "  WARNING: Failed to delete memory"
  fi
fi
echo ""

# ─── [3/4] Delete CloudFormation stack (if still exists) ──────────────────────
echo "[3/4] Checking for remaining CloudFormation stacks..."

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

# ─── [4/4] Remove local deploy directory ─────────────────────────────────────
echo "[4/4] Cleaning up local files..."

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
echo "  - Gateway:      ${GW_NAME} (+ targets: exa-search, aws-docs-mcp)"
echo "  - Memory:       ${AGENT_NAME}_memory"
echo "  - Harness:      ${AGENT_NAME}"
echo "  - Local files:  deploy-${AGENT_NAME}/"
echo ""
echo "Verify nothing remains:"
echo "  aws bedrock-agentcore-control list-agent-runtimes ${AWS_PROFILE_ARG} --region ${REGION} \\"
echo "    --query \"agentRuntimes[].{Name:agentRuntimeName,Status:status}\" --output table"
echo ""
echo "  aws bedrock-agentcore-control list-gateways ${AWS_PROFILE_ARG} --region ${REGION} \\"
echo "    --query \"items[].{Name:name,Status:status}\" --output table"
echo ""
