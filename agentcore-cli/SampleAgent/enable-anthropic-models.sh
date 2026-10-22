#!/bin/bash
# enable-anthropic-models.sh
# Accepts AWS Marketplace agreements for all active Anthropic foundation models
# in the specified region. Run this once per account/region to enable model access.
#
# Usage:
#   ./enable-anthropic-models.sh [region]
#
# Examples:
#   ./enable-anthropic-models.sh              # uses default region (us-east-1)
#   ./enable-anthropic-models.sh us-west-2    # specify region

set -euo pipefail

REGION="${1:-$(aws configure get region 2>/dev/null || echo "${AWS_DEFAULT_REGION:-us-east-1}")}"

echo "================================================"
echo " Enable Anthropic Models - Marketplace Agreement"
echo " Region: $REGION"
echo "================================================"
echo ""

# List all Anthropic foundation models and filter to ACTIVE status
echo "Discovering active Anthropic models..."
MODELS=$(aws bedrock list-foundation-models \
    --by-provider Anthropic \
    --region "$REGION" \
    --query "modelSummaries[?modelLifecycle.status=='ACTIVE'].modelId" \
    --output text)

if [ -z "$MODELS" ]; then
    echo "No active Anthropic models found in $REGION."
    exit 0
fi

echo "Found active models:"
for MODEL_ID in $MODELS; do
    echo "  - $MODEL_ID"
done
echo ""

# Track results
ACCEPTED=0
SKIPPED=0
FAILED=0

for MODEL_ID in $MODELS; do
    # Skip variant model IDs (those with context window suffixes like :0:128k)
    # Only process base model IDs to avoid duplicate agreements
    if [[ "$MODEL_ID" =~ :[0-9]+:[0-9]+k$ ]] || [[ "$MODEL_ID" =~ :[0-9]+:mm$ ]]; then
        continue
    fi

    echo "Processing: $MODEL_ID"

    # Get the offer token for this model
    OFFER_TOKEN=$(aws bedrock list-foundation-model-agreement-offers \
        --model-id "$MODEL_ID" \
        --region "$REGION" \
        --query "offers[0].offerToken" \
        --output text 2>/dev/null || echo "NONE")

    if [ "$OFFER_TOKEN" = "None" ] || [ "$OFFER_TOKEN" = "NONE" ] || [ -z "$OFFER_TOKEN" ]; then
        echo "  ⏭  No offer available (may already be accepted)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Check if agreement already exists
    EXISTING=$(aws bedrock get-foundation-model-availability \
        --model-id "$MODEL_ID" \
        --region "$REGION" \
        --query "agreementAvailability.status" \
        --output text 2>/dev/null || echo "UNKNOWN")

    if [ "$EXISTING" = "AVAILABLE" ]; then
        echo "  ✓  Already enabled"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Accept the agreement
    if aws bedrock create-foundation-model-agreement \
        --model-id "$MODEL_ID" \
        --offer-token "$OFFER_TOKEN" \
        --region "$REGION" \
        --output text >/dev/null 2>&1; then
        echo "  ✅ Agreement accepted"
        ACCEPTED=$((ACCEPTED + 1))
    else
        echo "  ❌ Failed to accept agreement"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "================================================"
echo " Summary"
echo "================================================"
echo " Accepted: $ACCEPTED"
echo " Skipped:  $SKIPPED"
echo " Failed:   $FAILED"
echo ""
echo "Note: It takes ~2 minutes for new agreements to propagate."
echo "After that, models can be used with inference profile IDs like:"
echo "  global.anthropic.claude-sonnet-4-5-20250929-v1:0"
echo "  us.anthropic.claude-sonnet-4-5-20250929-v1:0"
echo "================================================"
