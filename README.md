# Deployment Compliance Monitoring with SRE Agent

Detects and responds to non-compliant Azure Container App deployments using SRE Agent, Activity Logs, and KQL analysis.

## What it does

- **Compliant**: A Container App write from the approved pipeline identity using an image with valid immutable pipeline labels.
- **Non-compliant**: Deployments via Azure Portal or ad-hoc CLI, or images without the required labels.

When a Container App deployment is detected:
1. **Alert fires** → Activity Log alert on `Microsoft.App/containerApps/write`
2. **SRE Agent investigates** → Runs the `deployment-compliance-check` skill via KQL, Activity Log, ACR, and revision history.
3. **Classifies** → Caller identity is authoritative; immutable image labels confirm the image came from the pipeline.
4. **For non-compliant** → Activates the approval hook before any change. If no compliant image or prior revision exists, reports `NON-COMPLIANT BOOTSTRAP` without rollback.
5. **For compliant** → Confirms the deployment.

## Architecture

```
GitHub Actions (push to main)
    ↓
Build Docker image → Push to ACR
    ↓
Separate deployment mechanism (must be provisioned and validated)
    ↓
Container App update → Activity Log: containerApps/write
    ↓                          ↓
Alert Rule fires          Scheduled Task (every 30 min)
    ↓                          ↓
SRE Agent Response Plan   SRE Agent Compliance Scan
    ↓
deployment-compliance-check skill (KQL, Activity Log, ACR, revisions)
    ↓
Compliant? ──yes──► Confirm deployment
    ↓ no
Approval hook → Revert only when a known-good target exists
```

> **Important:** The Bicep currently provisions a placeholder Container App, but not an Event Grid/Automation deployment path. The checked-in workflow builds and pushes an image only. Provision and validate a deployment mechanism before treating a pushed image as deployed.

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
# Run this again after editing skills/ or hooks/ to sync their contents to the live agent.

# 3. Add GitHub repository secrets and variables (see below)

# 4. Provision and validate a Container App deployment mechanism.
# The checked-in workflow builds and pushes an image only; it does not update the app.

# 5. Authorize the GitHub connector
#    Open the OAuth URL printed by post-deploy.sh in your browser
```

### GitHub Secrets & Variables

| Type | Name | Value |
|------|------|-------|
| Secret | `ACR_USERNAME` | ACR admin username |
| Secret | `ACR_PASSWORD` | ACR admin password |
| Variable | `ACR_NAME` | Target ACR name (without `.azurecr.io`) |
| Optional secret | `AZURE_CREDENTIALS` | Required only if a direct Azure deployment stage is added |

## Testing Compliance

```bash
# Build-and-push test. This becomes a compliant deployment only after a
# separately provisioned deployment mechanism updates the Container App.
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
