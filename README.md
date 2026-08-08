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

# 2. Configure SRE Agent (connectors, skill, hook, response plan, scheduled task)
bash scripts/post-deploy.sh

# 3. Create service principal for GitHub Actions (run in Azure Portal Cloud Shell)
az ad sp create-for-rbac --name "compliancedemo-deploy" \
  --role Contributor \
  --scopes "/subscriptions/<SUB_ID>/resourceGroups/rg-compliancedemo" \
  --json-auth

# 4. Add GitHub secrets (see below)

# 5. Authorize GitHub connector
#    Open the OAuth URL printed by post-deploy.sh in your browser
```

### GitHub Secrets & Variables

| Type | Name | Value |
|------|------|-------|
| Secret | `ACR_USERNAME` | ACR admin username |
| Secret | `ACR_PASSWORD` | ACR admin password |
| Secret | `AZURE_CREDENTIALS` | JSON output from `az ad sp create-for-rbac --json-auth`; the identity needs permission to update the Container App |
| Variable | `ACR_NAME` | ACR name (without `.azurecr.io`) |
| Variable | `AZURE_RESOURCE_GROUP` | Resource group output by `azd provision` |
| Variable | `CONTAINER_APP_NAME` | Container App name output by `azd provision` |

The workflow pushes the SHA-tagged image, deploys its resolved digest, validates `/health`, and then stamps compliance tags.

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
