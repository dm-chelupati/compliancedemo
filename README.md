# Deployment Compliance Monitoring with SRE Agent

Detects and responds to non-compliant Azure Container App deployments using SRE Agent, Activity Logs, and KQL analysis.

## What it does

- **Compliant**: A GitHub Actions deployment by the approved noninteractive identity of an immutable image digest with valid pipeline labels.
- **Non-compliant**: A deployment by Azure Portal, interactive CLI, PowerShell, a user principal, or an image missing required immutable labels.
- **Non-compliant bootstrap**: A placeholder image with bootstrap tags, no compliant ACR image, and no prior compliant revision. This is reported but never rolled back.

When a Container App deployment is detected:
1. **Alert fires** -> Activity Log alert on `Microsoft.App/containerApps/write`
2. **SRE Agent investigates** -> Checks caller evidence, immutable image labels, and tags
3. **Classifies** -> Applies the signal-priority decision tree
4. **For a revertable violation** -> Uses the approval hook before proposing a known-good revision
5. **For bootstrap-only state** -> Reports that a compliant pipeline deployment is required

## Architecture

```
GitHub Actions (push to main)
    |
Build labeled image -> Push to ACR -> Direct digest deployment to Container App
    |
Activity Log: containerApps/write
    |                         |
Alert Rule fires         Scheduled Task (every 30 min)
    |                         |
SRE Agent Response Plan  SRE Agent Compliance Scan
    |
Caller + image labels + tags -> classify -> approval-gated rollback when eligible
```

## Deployed Resources

| Resource | Purpose |
|----------|---------|
| Container App | Sample workload (Express.js API) |
| ACR | Container image registry |
| Log Analytics Workspace | Activity Log storage + KQL queries |
| Activity Log Alert | Triggers on Container App write operations |
| SRE Agent | AI agent with Kusto connector, skill, hook, scheduled task |

## Setup

### Prerequisites
- Azure CLI + Azure Developer CLI (`azd`)
- Azure subscription with permissions to create resources
- GitHub account

### Deploy

```bash
# 1. Provision infrastructure
azd init
azd provision

# 2. Resolve the exact Container App scope
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
RESOURCE_GROUP="$(azd env get-value RESOURCE_GROUP_NAME)"
CONTAINER_APP_NAME="$(azd env get-value CONTAINER_APP_NAME)"
CONTAINER_APP_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/containerApps/${CONTAINER_APP_NAME}"

# 3. Create the GitHub Actions service principal at the Container App scope.
# Copy its JSON output to the AZURE_CREDENTIALS GitHub secret and record its clientId.
az ad sp create-for-rbac --name "compliancedemo-deploy" \
  --role "Container Apps Contributor" \
  --scopes "$CONTAINER_APP_ID" \
  --json-auth
CICD_SP_CLIENT_ID="<clientId from the JSON output>"
az role assignment create \
  --assignee "$CICD_SP_CLIENT_ID" \
  --role "Tag Contributor" \
  --scope "$CONTAINER_APP_ID"

# 4. Add GitHub secrets and variables (see below).

# 5. Configure SRE Agent with the approved pipeline client ID.
CICD_SP_CLIENT_ID="$CICD_SP_CLIENT_ID" bash scripts/post-deploy.sh

# 6. Authorize the GitHub connector.
#    Open the OAuth URL printed by post-deploy.sh in your browser.

# 7. Re-run this command after changing files under skills/ or hooks/.
#    The agent executes the installed configuration, not the repository copy.
CICD_SP_CLIENT_ID="$CICD_SP_CLIENT_ID" bash scripts/post-deploy.sh
```

`post-deploy.sh` also recreates the compliance scheduled task, so its prompt and the
installed skill and hook stay aligned with the repository. Verify the agent configuration
after the command completes before relying on a changed compliance policy.

### GitHub Secrets & Variables

| Type | Name | Value |
|------|------|-------|
| Secret | `ACR_USERNAME` | ACR admin username |
| Secret | `ACR_PASSWORD` | ACR admin password |
| Secret | `AZURE_CREDENTIALS` | JSON output from `az ad sp create-for-rbac --json-auth`; it has `Container Apps Contributor` and `Tag Contributor` only on the target Container App |
| Variable | `ACR_NAME` | ACR name (without `.azurecr.io`) |
| Variable | `AZURE_RESOURCE_GROUP` | Resource group output by `azd provision` |
| Variable | `CONTAINER_APP_NAME` | Container App name output by `azd provision` |
| Variable | `CICD_SERVICE_PRINCIPAL_CLIENT_ID` | `clientId` from the deployment service-principal JSON; this is stamped on the deployment and matched against Activity Log claims |

The workflow serializes deployments, stages an immutable image digest with zero traffic, validates the revision `/health` endpoint, promotes it only after validation, and restores the previous revision's traffic on failure.

## Testing Compliance

```bash
# Compliant deployment — push a code change via PR/merge
echo "// test" >> src/api/server.js
git add . && git commit -m "test deployment" && git push

# Non-compliant deployment — change via Portal
# Go to Azure Portal → Container App → Edit and Deploy → Change something

# Ask SRE Agent
"Check deployment compliance for the last hour"
```

## Files

```
├── .github/workflows/deploy-container-app.yml  # CI/CD pipeline
├── infra/                                       # Bicep infrastructure
├── scripts/post-deploy.sh                       # SRE Agent configuration
├── skills/deployment-compliance-check/          # KQL-based compliance skill
├── hooks/deployment-compliance-approval.yaml    # Approval hook for reverts
└── src/api/                                     # Sample Express.js app
```
