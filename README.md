# Deployment Compliance Monitoring with SRE Agent

Detects and responds to non-compliant Azure Container App deployments using SRE Agent, Activity Logs, and KQL analysis.

## What it does

- **Compliant**: A deployment made by the approved CI/CD identity whose image has all immutable pipeline labels, including `deployed-by=pipeline`, `commit-sha`, and `pipeline-run-id`.
- **Non-compliant**: A deployment from Azure Portal, ad-hoc CLI, or PowerShell, or an image missing required immutable labels.

When a Container App deployment is detected:
1. **Alert fires** → Activity Log alert on `Microsoft.App/containerApps/write`
2. **SRE Agent investigates** → Runs the `deployment-compliance-check` skill against Activity Log, ACR, tags, and revision state
3. **Classifies** → Caller identity is primary evidence; immutable image labels are required for a compliant result
4. **For non-compliant** → Reports the violation and identifies a rollback only when a healthy, label-compliant target exists
5. **For compliant** → Confirms the evidence and closes the alert when applicable

Scheduled scans are detection-only. They never change revisions, traffic, workflows, or images. A separate interactive response may modify a deployment only after the approval hook permits it and the replacement target is verified.

## Architecture

```
GitHub Actions (push to main)
    ↓
Build Docker image with immutable labels → Push to ACR
    ↓
Verified deployment path: direct Container App update
or provisioned Event Grid → Automation/managed identity
    ↓
Activity Log: containerApps/write
    ↓                          ↓
Alert Rule fires          Scheduled Task (every 30 min, detection-only)
    ↓                          ↓
SRE Agent Response Plan   SRE Agent Compliance Scan
    ↓
deployment-compliance-check skill (activity, ACR, tags, revisions)
    ↓
Compliant? ──yes──► Confirm / close alert
    ↓ no
Report violation → verify healthy compliant target → approval hook → interactive rollback
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

### Refreshing Agent Configuration

After changing the compliance skill, detection rules, approval hook, or scheduled-task template, rerun `bash scripts/post-deploy.sh` interactively. It uploads the current skill files and recreates `compliance-scan` with the detection-only prompt. Do not run this script from a scheduled scan because it changes agent configuration and task state.

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
