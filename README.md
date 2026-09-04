# Deployment Compliance Monitoring with SRE Agent

Detects and responds to non-compliant Azure Container App deployments using SRE Agent, Activity Logs, and KQL analysis.

## What it does

- **Compliant**: Images built by the approved GitHub Actions workflow with valid immutable compliance labels and deployed through a verified Azure deployment path.
- **Non-compliant**: Deployments by Azure Portal, ad-hoc CLI, or PowerShell; images without the required pipeline labels; and bootstrap placeholder state.

When a Container App deployment is detected:
1. **Alert fires** → Activity Log alert on `Microsoft.App/containerApps/write`
2. **SRE Agent investigates** → Checks Activity Log caller identity, immutable image labels, resource tags, revisions, and registry inventory.
3. **Classifies** → `COMPLIANT`, `NON-COMPLIANT`, `NON-COMPLIANT BOOTSTRAP`, or `INVESTIGATE`.
4. **For non-compliant** → Reports the finding. Reverts require explicit user approval and a known-good revision or verified CI/CD deployment path.
5. **For compliant** → Confirms and closes the alert.

Scheduled scans are detection-only. They never directly update a Container App or dispatch a workflow without validating the default-branch deployment path.

## Architecture

```
GitHub Actions (push to main)
    ↓
Build Docker image with immutable labels → Push to ACR
    ↓
Verified Azure-side deployment controller (for example, Automation Runbook)
    ↓
Container App update → Activity Log: containerApps/write
    ↓                          ↓
Alert Rule fires          Scheduled Task (every 30 min)
    ↓                          ↓
SRE Agent Response Plan   SRE Agent Compliance Scan
    ↓
deployment-compliance-check skill
    ↓
Compliant? ──yes──► Close alert
    ↓ no
Report finding → explicit user approval → revert only to a known-good target
```

> The workflow currently builds and pushes the image. Provision and validate the Azure-side deployment controller before treating a pipeline run as a completed Container App deployment.

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
| Secret | `AZURE_CREDENTIALS` | JSON output from `az ad sp create-for-rbac --json-auth` |
| Variable | `ACR_NAME` | ACR name (without `.azurecr.io`) |

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
