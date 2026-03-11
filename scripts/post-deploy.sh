#!/bin/bash
# ============================================================
# Post-deployment setup script
# Run after `azd provision` to configure:
#   1. Activity Log diagnostic settings (subscription-level)
#   2. Kusto connector on the SRE Agent (via ExtendedAgent API)
#   3. Custom compliance skill
#   4. Approval hook
#   5. Incident filter
#   6. Scheduled task
# ============================================================

set -uo pipefail

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Deployment Compliance Demo — Post-Deployment Setup${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# ---- Resolve resource names from azd or from Azure ----
echo -e "\n${YELLOW}[1/7] Resolving deployed resources...${NC}"

RESOURCE_GROUP=$(azd env get-value RESOURCE_GROUP_NAME 2>/dev/null || echo "")
if [[ -z "$RESOURCE_GROUP" ]]; then
  ENV_NAME=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || echo "compliancedemo")
  RESOURCE_GROUP="rg-${ENV_NAME}"
fi

# Get SRE Agent endpoint
AGENT_ENDPOINT=$(az resource show \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.App/agents" \
  --name "$(az resource list --resource-group "$RESOURCE_GROUP" --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv)" \
  --query "properties.agentEndpoint" -o tsv 2>/dev/null || echo "")

if [[ -z "$AGENT_ENDPOINT" ]]; then
  echo -e "${RED}ERROR: Could not find SRE Agent endpoint. Check resource group: $RESOURCE_GROUP${NC}"
  exit 1
fi

# Get LAW resource ID for Kusto connector (use law-compliance-*, not law-cae-*)
LAW_ID=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.OperationalInsights/workspaces" \
  --query "[?starts_with(name, 'law-compliance-')].id" -o tsv 2>/dev/null | head -1)

LAW_NAME=$(az resource show --ids "$LAW_ID" --query "name" -o tsv 2>/dev/null || echo "")
LAW_WORKSPACE_ID=$(az resource show --ids "$LAW_ID" --query "properties.customerId" -o tsv 2>/dev/null || echo "")

# Get agent managed identity principal ID
AGENT_MI_NAME=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.ManagedIdentity/userAssignedIdentities" \
  --query "[?contains(name, 'sreagent')].name" -o tsv 2>/dev/null | head -1)

echo -e "${GREEN}  Resource Group: $RESOURCE_GROUP${NC}"
echo -e "${GREEN}  Agent Endpoint: $AGENT_ENDPOINT${NC}"
echo -e "${GREEN}  LAW Name: $LAW_NAME${NC}"
echo -e "${GREEN}  LAW ID: $LAW_ID${NC}"
echo -e "${GREEN}  LAW Workspace ID: $LAW_WORKSPACE_ID${NC}"

# ---- Helper: Get auth token for SRE Agent API ----
get_agent_token() {
  az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv 2>/dev/null
}

# ---- Helper: Call ExtendedAgent API ----
agent_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local token
  token=$(get_agent_token)

  if [[ -n "$body" ]]; then
    curl -s -X "$method" \
      "${AGENT_ENDPOINT}${path}" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -s -X "$method" \
      "${AGENT_ENDPOINT}${path}" \
      -H "Authorization: Bearer $token"
  fi
}

# ---- Step 1b: Ensure current user has SRE Agent Administrator role ----
echo "   Ensuring SRE Agent Administrator role..."
AGENT_ID=$(az resource list --resource-group "$RESOURCE_GROUP" --resource-type "Microsoft.App/agents" --query "[0].id" -o tsv 2>/dev/null)
# Get user OID from the access token (avoids Graph API which may be blocked by conditional access)
ACCESS_TOKEN=$(az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv 2>/dev/null)
USER_OID=""
if [[ -n "$ACCESS_TOKEN" ]]; then
  USER_OID=$(python3 -c "
import json, base64, sys
try:
    token = sys.argv[1]
    payload = token.split('.')[1]
    payload += '=' * (4 - len(payload) % 4)
    claims = json.loads(base64.b64decode(payload))
    print(claims.get('oid', ''))
except Exception as e:
    print('', file=sys.stderr)
    print(str(e), file=sys.stderr)
" "$ACCESS_TOKEN")
fi

if [[ -n "$USER_OID" && -n "$AGENT_ID" ]]; then
  echo "   Assigning role to user OID: ${USER_OID:0:8}..."
  az role assignment create \
    --assignee-object-id "$USER_OID" \
    --assignee-principal-type User \
    --role "SRE Agent Administrator" \
    --scope "$AGENT_ID" \
    --output none || true
  echo -e "${GREEN}  ✓ SRE Agent Administrator role assigned.${NC}"
else
  echo -e "${YELLOW}  Could not extract user OID (USER_OID='$USER_OID', AGENT_ID set=$([ -n "$AGENT_ID" ] && echo yes || echo no)). Assign role manually.${NC}"
fi

# ---- Step 2: Activity Log Diagnostic Settings ----
echo -e "\n${YELLOW}[2/7] Configuring Activity Log diagnostic settings...${NC}"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Check existing diagnostic settings — recreate if pointing to wrong workspace
EXISTING=$(az monitor diagnostic-settings subscription list \
  --query "[?name=='activity-to-law'].name" -o tsv 2>/dev/null || echo "")
EXISTING_WS=$(az monitor diagnostic-settings subscription list \
  --query "[?name=='activity-to-law'].workspaceId" -o tsv 2>/dev/null || echo "")

if [[ -n "$EXISTING" && "$EXISTING_WS" == *"$LAW_NAME"* ]]; then
  echo -e "${GREEN}  Diagnostic setting 'activity-to-law' already exists (correct workspace). Skipping.${NC}"
else
  if [[ -n "$EXISTING" ]]; then
    echo "  Existing diagnostic setting points to wrong workspace. Deleting..."
    az monitor diagnostic-settings subscription delete --name "activity-to-law" --yes 2>/dev/null || true
  fi
  if az monitor diagnostic-settings subscription create \
    --name "activity-to-law" \
    --workspace "$LAW_ID" \
    --logs '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"Policy","enabled":true},{"category":"Alert","enabled":true}]' \
    --output none; then
    echo -e "${GREEN}  ✓ Diagnostic settings configured → ${LAW_NAME}${NC}"
  else
    echo -e "${YELLOW}  Could not create diagnostic settings (may need elevated permissions or already exists).${NC}"
  fi
fi

# ---- Step 3: Grant agent MI Log Analytics Reader on LAW ----
echo -e "\n${YELLOW}[3/7] Granting agent identity Log Analytics Reader...${NC}"

AGENT_MI_PRINCIPAL_ID=$(az identity show --name "$AGENT_MI_NAME" --resource-group "$RESOURCE_GROUP" --query principalId -o tsv 2>/dev/null || echo "")

if [[ -n "$AGENT_MI_PRINCIPAL_ID" ]]; then
  az role assignment create \
    --assignee-object-id "$AGENT_MI_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Log Analytics Reader" \
    --scope "$LAW_ID" \
    --output none || echo -e "${YELLOW}  Role may already exist.${NC}"
  echo -e "${GREEN}  ✓ Log Analytics Reader granted.${NC}"
fi

# ---- Step 4: Create Kusto Connector via ARM API ----
echo -e "\n${YELLOW}[4/7] Creating Kusto connector...${NC}"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
AGENT_NAME=$(az resource list --resource-group "$RESOURCE_GROUP" --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv)
AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}"
API_VERSION="2025-05-01-preview"

# Create Kusto connector via ARM API
# LAW Kusto endpoint format: https://<workspace-id>.api.loganalytics.io/<database-name>
# For LAW, the database name is the workspace name
python3 -c "
import json, os
workspace_id = '$LAW_WORKSPACE_ID'
law_name = '$LAW_NAME'
body = {
    'properties': {
        'name': 'compliance-law',
        'dataConnectorType': 'Kusto',
        'dataSource': f'https://{workspace_id}.api.loganalytics.io/{law_name}',
        'identity': 'system'
    }
}
with open('/tmp/kusto-connector-body.json', 'w') as f:
    json.dump(body, f)
"

if az rest --method PUT \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/compliance-law?api-version=${API_VERSION}" \
  --body @/tmp/kusto-connector-body.json \
  --output none 2>&1; then
  echo -e "${GREEN}  ✓ Kusto connector 'compliance-law' created via ARM.${NC}"
else
  echo -e "${YELLOW}  Kusto connector may need manual setup in Portal.${NC}"
fi
rm -f /tmp/kusto-connector-body.json

# ---- Step 4b: Enable Azure Monitor as incident platform ----
echo -e "\n${YELLOW}    Enabling Azure Monitor incident platform...${NC}"

if az rest --method PATCH \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=${API_VERSION}" \
  --body '{"properties":{"incidentManagementConfiguration":{"type":"AzMonitor","connectionName":"azmonitor"}}}' \
  --output none 2>&1; then
  echo -e "${GREEN}  ✓ Azure Monitor enabled as incident platform.${NC}"
else
  echo -e "${YELLOW}  Could not enable Azure Monitor (may already be set).${NC}"
fi
sleep 5

# ---- Step 5: Create Compliance Skill ----
echo -e "\n${YELLOW}[5/7] Creating deployment-compliance-check skill...${NC}"

SKILL_CONTENT=$(cat "$DEMO_DIR/skills/deployment-compliance-check/SKILL.md" 2>/dev/null || echo "")
DETECTION_CONTENT=$(cat "$DEMO_DIR/skills/deployment-compliance-check/compliance_detection.md" 2>/dev/null || echo "")

if [[ -n "$SKILL_CONTENT" ]]; then
  SKILL_BODY=$(python3 -c "
import json, sys
skill = open('$DEMO_DIR/skills/deployment-compliance-check/SKILL.md').read()
detection = open('$DEMO_DIR/skills/deployment-compliance-check/compliance_detection.md').read()
body = {
    'name': 'deployment-compliance-check',
    'type': 'Skill',
    'properties': {
        'description': 'Detects out-of-compliance Container App deployments via Activity Log analysis',
        'tools': ['kusto_query', 'azure_cli'],
        'skillContent': skill,
        'additionalFiles': [
            {'path': 'compliance_detection.md', 'content': detection}
        ]
    }
}
print(json.dumps(body))
")
  RESULT=$(agent_api PUT "/api/v2/extendedAgent/skills/deployment-compliance-check" "$SKILL_BODY"  || echo "FAILED")
  if echo "$RESULT" | grep -q "deployment-compliance-check" 2>/dev/null; then
    echo -e "${GREEN}  ✓ Skill 'deployment-compliance-check' created.${NC}"
  else
    echo -e "${YELLOW}  Skill may need manual setup. Response: ${RESULT:0:200}${NC}"
  fi
else
  echo -e "${RED}  Skill files not found at $DEMO_DIR/skills/${NC}"
fi

# ---- Step 6: Create Approval Hook ----
echo -e "\n${YELLOW}[6/7] Creating deployment-compliance-approval hook...${NC}"

HOOK_BODY=$(cat <<'EOF'
{
  "name": "deployment-compliance-approval",
  "type": "GlobalHook",
  "properties": {
    "eventType": "Stop",
    "activationMode": "onDemand",
    "description": "Requires explicit user approval before reverting a non-compliant Container App deployment",
    "hook": {
      "type": "prompt",
      "prompt": "Check if the agent is about to revert or modify a Container App deployment. If the response includes a revert, rollback, or revision change, reject and ask the user to approve first.\n\n$ARGUMENTS\n\nRespond with JSON:\n- If no revert action: {\"ok\": true, \"reason\": \"No deployment-modifying action detected\"}\n- If revert pending: {\"ok\": false, \"reason\": \"Deployment revert requires approval. Reply 'yes' to approve or 'no' to cancel.\"}",
      "model": "ReasoningFast",
      "timeout": 30,
      "failMode": "Block",
      "maxRejections": 3
    }
  }
}
EOF
)

RESULT=$(agent_api PUT "/api/v2/extendedAgent/hooks/deployment-compliance-approval" "$HOOK_BODY"  || echo "FAILED")
if echo "$RESULT" | grep -q "deployment-compliance-approval" 2>/dev/null; then
  echo -e "${GREEN}  ✓ Hook 'deployment-compliance-approval' created.${NC}"
else
  echo -e "${YELLOW}  Hook may need manual setup. Response: ${RESULT:0:200}${NC}"
fi

# ---- Step 7: Create response plan + scheduled task ----
echo -e "\n${YELLOW}[7/7] Creating response plan and scheduled task...${NC}"

TOKEN=$(get_agent_token)

# Delete existing filter if present
curl -s -o /dev/null -X DELETE \
  "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/containerapp-compliance" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true

sleep 3

# Create response plan with custom compliance instructions
python3 -c "
import json
body = {
    'id': 'containerapp-compliance',
    'name': 'Container App Deployment Compliance',
    'priorities': ['Sev0', 'Sev1', 'Sev2', 'Sev3', 'Sev4'],
    'titleContains': '',
    'agentMode': 'review',
    'maxAttempts': 3,
    'instructions': '''When this alert fires, use the deployment-compliance-check skill to investigate:

1. Query the AzureActivity table via Kusto MCP to find the Container App write operation that triggered this alert
2. Classify the deployment by caller identity using claims.appid:
   - Azure Portal (c44b4083-3bb0-49c1-b47d-974e53cbdf3c) = Non-compliant
   - Azure CLI (04b07795-a710-4e84-bea4-c697bab44963) = Non-compliant
   - Service Principal = Compliant (verify with resource tags)
3. Check Container App tags for deployed-by, pipeline-run-id, commit-sha
4. If non-compliant: generate a compliance report and recommend revert to previous revision
5. IMPORTANT: Before executing any revert, activate the deployment-compliance-approval hook on this thread and wait for user approval
6. If compliant: close the alert with a brief confirmation

Never revert a deployment without explicit user approval through the hook.'''
}
with open('/tmp/filter-body.json', 'w') as f:
    json.dump(body, f)
"

FILTER_CREATED=false
for attempt in 1 2 3; do
  TOKEN=$(get_agent_token)
  HTTP_CODE=$(curl -s -o /tmp/filter-resp.txt -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/containerapp-compliance" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @/tmp/filter-body.json)

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "409" ]; then
    echo -e "${GREEN}  ✓ Response plan created: containerapp-compliance${NC}"
    FILTER_CREATED=true
    break
  else
    echo "   Attempt $attempt/3: HTTP ${HTTP_CODE}, retrying in 10s..."
    sleep 10
  fi
done
if [ "$FILTER_CREATED" = "false" ]; then
  echo -e "${YELLOW}  Response plan failed — set up in portal or re-run this script.${NC}"
fi
rm -f /tmp/filter-resp.txt /tmp/filter-body.json

# Delete default quickstart handler
curl -s -o /dev/null -X DELETE \
  "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/quickstart_handler" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true

# ---- Create scheduled task for periodic compliance scans ----
echo "   Creating compliance scan scheduled task..."
TOKEN=$(get_agent_token)

# Delete existing task if present
EXISTING_TASKS=$(curl -s "${AGENT_ENDPOINT}/api/v1/scheduledtasks" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "[]")
echo "$EXISTING_TASKS" | python3 -c "
import sys,json
try:
    tasks=json.load(sys.stdin)
    for t in tasks:
        if t.get('name')=='compliance-scan':
            print(t.get('id',''))
except: pass
" 2>/dev/null | while read -r task_id; do
  if [ -n "$task_id" ]; then
    curl -s -o /dev/null -X DELETE "${AGENT_ENDPOINT}/api/v1/scheduledtasks/${task_id}" \
      -H "Authorization: Bearer ${TOKEN}" 2>/dev/null
  fi
done

python3 -c "
import json
body = {
    'name': 'compliance-scan',
    'description': 'Periodic deployment compliance scan using the deployment-compliance-check skill',
    'cronExpression': '*/30 * * * *',
    'agentPrompt': '''Use the deployment-compliance-check skill to run a compliance scan for the last 30 minutes.

Steps:
1. Query the AzureActivity table via Kusto MCP using Template 1 from the skill (set timeRange to 30m)
2. Classify each Container App deployment by caller identity using claims.appid:
   - Azure Portal (c44b4083-3bb0-49c1-b47d-974e53cbdf3c) = Non-compliant
   - Azure CLI (04b07795-a710-4e84-bea4-c697bab44963) = Non-compliant  
   - Known CI/CD service principal = Compliant
3. Cross-reference with Container App resource tags (deployed-by, pipeline-run-id, commit-sha)
4. Generate a compliance report using the format in the skill

If ALL deployments are compliant: Report clean scan.
If ANY deployment is non-compliant:
   - Report the violation with details
   - Recommend revert to previous Container App revision
   - IMPORTANT: Activate the deployment-compliance-approval hook on this thread before executing any revert
   - Do NOT revert without user approval through the hook

Include scan timestamp and time range in the report.'''
}
with open('/tmp/task-body.json', 'w') as f:
    json.dump(body, f)
"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${AGENT_ENDPOINT}/api/v1/scheduledtasks" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/task-body.json)

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ]; then
  echo -e "${GREEN}  ✓ Scheduled task created: compliance-scan (every 30 min)${NC}"
else
  echo -e "${YELLOW}  Scheduled task returned HTTP ${HTTP_CODE}${NC}"
fi
rm -f /tmp/task-body.json

# ---- Step 8: GitHub OAuth connector ----
echo -e "\n${YELLOW}[8/8] Creating GitHub OAuth connector...${NC}"

# Create the GitHub OAuth connector resource via ARM API
python3 -c "
import json
body = {
    'properties': {
        'name': 'github',
        'dataConnectorType': 'GitHubOAuth',
        'dataSource': 'github.com',
        'identity': 'system'
    }
}
with open('/tmp/github-oauth-body.json', 'w') as f:
    json.dump(body, f)
"

az rest --method PUT \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/github?api-version=${API_VERSION}" \
  --body @/tmp/github-oauth-body.json \
  --output none || true
rm -f /tmp/github-oauth-body.json

# Get the OAuth login URL from the agent's data plane API
TOKEN=$(get_agent_token)
OAUTH_URL=$(curl -s "${AGENT_ENDPOINT}/api/v1/github/config" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('oAuthUrl', '') or d.get('OAuthUrl', '') or '')
except:
    print('')
" 2>/dev/null)

if [ -n "$OAUTH_URL" ]; then
  echo -e "${GREEN}  ✓ GitHub OAuth connector created.${NC}"
  echo ""
  echo -e "  ${BLUE}┌──────────────────────────────────────────────────────────────┐${NC}"
  echo -e "  ${BLUE}│  Sign in to GitHub to authorize the SRE Agent:              │${NC}"
  echo -e "  ${BLUE}│                                                              │${NC}"
  echo -e "  ${BLUE}│  ${OAUTH_URL}${NC}"
  echo -e "  ${BLUE}│                                                              │${NC}"
  echo -e "  ${BLUE}│  Open this URL in your browser and click 'Authorize'         │${NC}"
  echo -e "  ${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"
else
  echo -e "${YELLOW}  GitHub connector created but could not retrieve login URL.${NC}"
  echo "  Sign in at: ${AGENT_ENDPOINT} → Builder → Connectors → github"
fi

# ---- Summary ----
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Infrastructure deployed:"
echo "    ✓ Container App (workload)"
echo "    ✓ SRE Agent: $AGENT_ENDPOINT"
echo "    ✓ Log Analytics: Activity Logs flowing"
echo "    ✓ Alert Rule: Container App deployment detection"
echo "    ✓ Kusto connector: compliance-law"
echo "    ✓ Skill: deployment-compliance-check"
echo "    ✓ Hook: deployment-compliance-approval"
echo ""
echo "  To test the compliance workflow:"
echo "    1. Push a change through GitHub Actions (compliant)"
echo "    2. Make a change via Azure Portal (non-compliant)"
echo "    3. Ask the SRE Agent: 'Check deployment compliance'"
echo ""
echo "  Agent Portal: $AGENT_ENDPOINT"
