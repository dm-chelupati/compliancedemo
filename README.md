# Deployment Compliance Monitoring with SRE Agent

Detects and responds to non-compliant Azure Container App deployments using SRE Agent, Activity Logs, and KQL analysis.

## What it does

- **Compliant**: Deployments via this CI/CD pipeline (GitHub Actions) — tagged with `deployed-by=pipeline`, `commit-sha`, `pipeline-run-id`
- **Non-compliant**: Deployments via Azure Portal or ad-hoc CLI — detected by `claims.appid` in Activity Log
- **Bootstrap / not yet evaluable**: Freshly provisioned app is still on the seeded fallback image and the target ACR repository has no pushed workload image yet

When a Container App deployment is detected:
1. **Alert fires** → Activity Log alert on `Microsoft.App/containerApps/write`
2. **SRE Agent investigates** → Queries Log Analytics first, then falls back to ARM Activity Log if ingestion is delayed
3. **Classifies** → Portal app ID `c44b4083...`, Azure CLI app ID `04b07795-8ddb-461a-bbee-02f9e1bf7b46`, or any user principal caller = non-compliant
4. **Verifies image labels** → Missing immutable pipeline labels in ACR is non-compliant even if the deployer looks automated, unless the app is still in the initial bootstrap state
5. **For non-compliant interactive investigations** → Activates approval hook, recommends revert to previous revision
6. **For non-compliant scheduled scans** → Reports the violation and recommended rollback, but defers remediation until an interactive approval step is available
7. **For compliant** → Confirms and closes the alert
8. **For bootstrap** → Reports that the environment is waiting for the first approved pipeline build and does not recommend revert action

## Architecture

```
GitHub Actions (push to main)
    ↓
Build Docker image → Push to ACR
    ↓
Event Grid image push event
    ↓
Automation Runbook → az containerapp update
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

## Deployed Resources

| Resource | Purpose |
|----------|---------|
| Container App | Sample workload (Express.js API) |
| ACR | Container image registry |
| Log Analytics Workspace | Activity Log storage + KQL queries |
| Activity Log Alert | Triggers on Container App write operations |
| SRE Agent | AI agent with built-in Log Analytics access, skill, hook, and scheduled task |

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

# 3. Resolve deployed names from azd output
RESOURCE_GROUP=$(azd env get-value RESOURCE_GROUP_NAME)
ACR_NAME=$(azd env get-value ACR_NAME)

# 4. Get ACR admin credentials for the GitHub workflow
ACR_USERNAME=$(az acr credential show --name "$ACR_NAME" --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --query 'passwords[0].value' -o tsv)

# 5. Add GitHub secrets and variables (see below)

# 6. Authorize the GitHub connector
#    Open the OAuth URL printed by post-deploy.sh in your browser
```

After provisioning, the Container App initially runs the seeded fallback image until the first GitHub Actions build pushes the real workload image to ACR. Compliance scans during that window should report `BOOTSTRAP / NOT YET EVALUABLE`, not `NON-COMPLIANT`.

During that bootstrap window, the only revision can also appear `Unhealthy` / `Degraded` because the seeded sample image listens on port `80` while the Container App ingress targets port `8080`. A status message such as `TargetPort 8080 does not match the listening port 80.` is expected bootstrap behavior for this demo and is not, by itself, a compliance violation.

If the compliance Log Analytics workspace returns zero rows during that bootstrap window, but ARM Activity Log fallback shows only the initial `Microsoft.App/containerApps/write` create/update event and the target ACR catalog is still empty (including `{"repositories": null}`), keep the app classified as `BOOTSTRAP / NOT YET EVALUABLE`. That is a historical monitoring-gap case for the bootstrap event, not a deployment-policy violation.

The current repository build workflow pushes images to ACR only. A separate rollout step must update the Container App to a newly pushed image before the deployment can be evaluated as compliant or non-compliant beyond bootstrap.

If Azure discovery is unavailable during a scheduled scan, the agent should report `BLOCKED / UNABLE TO EVALUATE` with the exact error evidence and avoid remediation based on partial data.

### GitHub Secrets & Variables

| Type | Name | Value |
|------|------|-------|
| Secret | `ACR_USERNAME` | ACR admin username |
| Secret | `ACR_PASSWORD` | ACR admin password |
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
