# Deployment Compliance Monitoring with SRE Agent

Detects and responds to non-compliant Azure Container App deployments using SRE Agent, Activity Logs, and KQL analysis.

## What it does

- **Compliant**: An approved deployment path updates the Container App and the active ACR image has the immutable `deployed-by=pipeline`, `commit-sha`, and `pipeline-run-id` labels.
- **Non-compliant**: Deployments via Azure Portal or ad-hoc CLI, or images that lack the required immutable labels.
- **Important**: Building and pushing an image alone does not deploy the Container App or establish compliance.

When a Container App deployment is detected:
1. **Alert fires** → Activity Log alert on `Microsoft.App/containerApps/write`
2. **SRE Agent investigates** → Runs the `deployment-compliance-check` skill via KQL
3. **Classifies** → Portal/CLI user callers are non-compliant; service principals still require ACR image-label validation
4. **For non-compliant** → Activates approval hook, recommends a verified rollback target
5. **For compliant** → Confirms and closes the alert

## Architecture

```
GitHub Actions (push to main)
    ↓
Build Docker image → Push to ACR
    ↓
Approved deployment component
(workflow deploy job or Event Grid → Automation Runbook)
    ↓
Container App revision update
    ↓
Activity Log: containerApps/write
    ↓                          ↓
Alert Rule fires          Scheduled Task (every 30 min)
    ↓                          ↓
SRE Agent Response Plan   SRE Agent Compliance Scan
    ↓
deployment-compliance-check skill (KQL queries)
    ↓
Compliant? ──yes──► Close alert
    ↓ no
Activate approval hook → Wait for user → Revert revision
```

The current infrastructure template provisions neither an Event Grid/Automation deployment component nor a workflow deployment job. Add and validate one before treating ACR pushes as Container App deployments.

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

# 3. Configure the build workflow secrets and variables below.

# 4. Add an approved deployment component that updates the Container App
#    (a workflow deploy job or Event Grid → Automation Runbook), then verify its
#    managed identity or service principal and RBAC scope.

# 5. Authorize GitHub connector
#    Open the OAuth URL printed by post-deploy.sh in your browser
```

### GitHub Secrets & Variables

| Type | Name | Value |
|------|------|-------|
| Secret | `ACR_USERNAME` | ACR admin username for the build-and-push workflow |
| Secret | `ACR_PASSWORD` | ACR admin password for the build-and-push workflow |
| Variable | `ACR_NAME` | Provisioned ACR name (without `.azurecr.io`); reconcile the workflow with this value before enabling it |

If a workflow deploy job is used, configure its Azure identity separately with least-privilege access to the target Container App. The shipped workflow currently only builds and pushes images.

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
