# Deployment Compliance Monitoring with SRE Agent

Detects and responds to non-compliant Azure Container App deployments using SRE Agent, Activity Logs, and KQL analysis.

## What it does

- **Compliant**: A CI-built image with immutable pipeline labels is deployed by an approved noninteractive identity.
- **Non-compliant**: Portal, interactive CLI, or PowerShell writes; images with missing CI labels; and placeholder bootstrap images without a good rollback target.

When a Container App deployment is detected:
1. **Alert fires** -> Activity Log alert on `Microsoft.App/containerApps/write`.
2. **SRE Agent investigates** -> Checks the caller, immutable image labels, and resource tags.
3. **Classifies** -> A known user or CLI caller is non-compliant; labels and caller must both validate for compliance.
4. **For a rollback candidate** -> The approval hook requires explicit confirmation before traffic or revision changes.
5. **For bootstrap drift** -> Reports the missing or broken deployment path; it does not attempt a rollback without a compliant image or prior revision.

## Architecture

```
GitHub Actions (push to main)
    |
    v
Build labeled Docker image -> Push to ACR
    |
    v
Separately provisioned deployment mechanism updates Container App
    |
    v
Activity Log: containerApps/write
    |                          |
    v                          v
Alert Rule fires          Scheduled Task (every 30 min)
    |                          |
    +------------+-------------+
                 v
   deployment-compliance-check skill
                 |
     +-----------+------------+
     |                        |
     v                        v
Compliant                 Non-compliant
                             |
              +--------------+--------------+
              |                             |
              v                             v
  Verified rollback target           Bootstrap-only drift
  Approval hook before action        Report deployment-path repair
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

# 3. Provision a separate deployment mechanism that updates the Container App
#    after a labeled image is pushed. Its managed identity or service principal
#    must be the approved Activity Log caller.

# 4. Add GitHub secrets and the ACR_NAME repository variable (see below)

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
