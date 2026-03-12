#!/bin/bash
# ============================================================
# Deploy the latest image from ACR to the Container App
# For local/manual deploys — the primary path is GitHub Actions.
#
# Usage:
#   bash scripts/deploy.sh                    # deploy :latest
#   bash scripts/deploy.sh <commit-sha>       # deploy specific version
#
# Note: Manual runs of this script will show Azure CLI appid
# (04b07795-...) in Activity Log → detected as non-compliant.
# ============================================================
set -euo pipefail

RESOURCE_GROUP="rg-compliancedemo"
CONTAINER_APP="ca-api-compliancedemo"
ACR_NAME="acrcompliancedemoenqgb2"
IMAGE="compliance-demo-api"

# Compliance tags — required for deployment-compliance-check signal 2
DEPLOYED_BY="pipeline"
DEPLOYMENT_METHOD="${DEPLOYMENT_METHOD:-script}"
PIPELINE_RUN_ID="${GITHUB_RUN_ID:-local-$(date +%s)}"
COMMIT_SHA="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
WORKFLOW="${GITHUB_WORKFLOW:-manual}"
REPOSITORY="${GITHUB_REPOSITORY:-dm-chelupati/compliancedemo}"
BRANCH="${GITHUB_REF_NAME:-$(git branch --show-current 2>/dev/null || echo unknown)}"

TAG="${1:-latest}"
FULL_IMAGE="${ACR_NAME}.azurecr.io/${IMAGE}:${TAG}"

echo "Deploying: $FULL_IMAGE"
az containerapp update \
  --name "$CONTAINER_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --image "$FULL_IMAGE" \
  --tags \
    deployed-by="$DEPLOYED_BY" \
    deployment-method="$DEPLOYMENT_METHOD" \
    pipeline-run-id="$PIPELINE_RUN_ID" \
    commit-sha="$COMMIT_SHA" \
    workflow="$WORKFLOW" \
    repository="$REPOSITORY" \
    branch="$BRANCH" \
  --output none

FQDN=$(az containerapp show \
  --name "$CONTAINER_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

echo "✅ Deployed! App: https://$FQDN"
sleep 10
echo "Health check:"
curl -s "https://$FQDN/health" | python3 -m json.tool
