---
name: deployment-compliance-check
description: >
  Detects out-of-compliance Azure Container App deployments using a three-signal
  approach: Activity Log caller identity, resource tags, and Docker image labels.
  Image labels are the strongest signal — immutable once pushed to ACR.
  Primary method: Azure CLI (no LAW dependency). Fallback: KQL via Log Analytics.
tools:
  - azure_cli
  - kusto_query
---

# Deployment Compliance Check

## Configuration

| Setting | Value |
|---|---|
| Resource Group | `rg-compliancedemo` |
| Subscription | `cbf44432-7f45-4906-a85d-d2b14a1e8328` |
| Container App | `ca-api-compliancedemo` |
| ACR Registry | `acrcompliancedemoenqgb2` |
| ACR Image Name | `compliance-demo-api` |
| Automation Account | `auto-compliancedemo` |
| Automation MI PrincipalId | `119bed36-0070-4466-9009-0773f412c204` |
| Log Analytics Workspace ID (GUID) | `17c5506a-8871-4793-8470-c400a2114997` *(fallback only)* |
| Log Analytics Workspace Resource | `law-compliance-compliancedemo` *(fallback only)* |

## Pipeline Architecture

```
git push → GitHub Actions → Docker build (with labels) → ACR push
                                                            ↓
                                              Event Grid (ImagePushed)
                                                            ↓
                                              Automation Runbook (MI)
                                                            ↓
                                              Container App update (ARM)
```

The CI/CD pipeline uses **zero external Azure AD authentication** from GitHub:
1. GitHub Actions builds the Docker image with **immutable compliance labels**
2. Pushes to ACR using admin credentials (no OIDC / federated identity needed)
3. ACR emits an Event Grid `ImagePushed` event
4. Event Grid triggers an Automation Runbook via webhook
5. Runbook uses its **system-assigned Managed Identity** to update the Container App via ARM REST API

## When to use this skill

- When asked to check deployment compliance for Container Apps
- When investigating who made a configuration change
- When a deployment alert fires and you need to classify the change
- During periodic compliance scans (scheduled tasks)
- When verifying that a deployment came through the approved pipeline

## Detection Strategy — Three Signals

Use **three signals** together for high-confidence classification.
See [compliance_detection.md](compliance_detection.md) for the full decision tree.

### Signal 1: Caller Identity (Activity Log) — WHO deployed

Query the Activity Log. The `Caller` field and `claims.appid` identify the deployer:

| Caller / claims.appid | Source | Classification |
|---|---|---|
| `119bed36-0070-4466-9009-0773f412c204` | Automation Runbook MI (Event Grid pipeline) | **Compliant** |
| `c44b4083-3bb0-49c1-b47d-974e53cbdf3c` | Azure Portal | **Non-compliant** |
| `04b07795-a710-4e84-bea4-c697bab44963` | Azure CLI (interactive) | **Non-compliant** |
| `1950a258-227b-4e31-a9cf-717495945fc2` | Azure PowerShell | **Non-compliant** |
| `872cd9fa-d31f-45e0-9eab-6e460a02d1f1` | Visual Studio | **Non-compliant** |
| `0a7bdc5c-7b57-40be-9939-d4c5fc7cd417` | Azure Mobile App | **Non-compliant** |
| Caller contains `@` | User principal (manual) | **Non-compliant** |
| Any other SP GUID | Unknown service principal | **Investigate** |

### Signal 2: Resource Tags (Container App) — WHAT was stamped

The Automation Runbook stamps these tags on every pipeline deployment:

| Tag | Example value |
|---|---|
| `deployed-by` | `pipeline` |
| `deployment-method` | `eventgrid-automation` |

> **WARNING**: Tags alone are NOT sufficient. The Automation Runbook stamps these tags
> on every deployment it processes — including images pushed manually to ACR that trigger
> Event Grid. Tags are a secondary confirmation only.

### Signal 3: Docker Image Labels (ACR) — HOW it was built ⭐

**This is the strongest compliance signal.** Docker image labels are baked in at build
time by GitHub Actions and are **immutable once pushed to ACR**. They cannot be added,
modified, or faked after the image is built.

The CI/CD pipeline bakes these labels into every image:

| Label | Source | Example |
|---|---|---|
| `deployed-by` | Hardcoded | `pipeline` |
| `commit-sha` | `${{ github.sha }}` | `d065f2440e45e00...` |
| `pipeline-run-id` | `${{ github.run_id }}` | `22986679132` |
| `branch` | `${{ github.ref_name }}` | `main` |
| `repository` | `${{ github.repository }}` | `dm-chelupati/compliancedemo` |
| `workflow` | `${{ github.workflow }}` | `Deploy Container App` |
| `org.opencontainers.image.source` | OCI standard | `https://github.com/dm-chelupati/compliancedemo` |
| `org.opencontainers.image.revision` | OCI standard | `d065f2440e45e00...` |

**An image pushed via Azure Portal or `docker push` will NOT have these labels.**
This is what makes image labels the definitive compliance signal.

## Scheduled Task Workflow

When running as a scheduled compliance scan, execute these steps in order:

### Step 1: Get the current running image

```bash
az containerapp show \
  --name ca-api-compliancedemo \
  --resource-group rg-compliancedemo \
  --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 \
  --query "properties.template.containers[0].image" -o tsv
```

This returns something like: `acrcompliancedemoenqgb2.azurecr.io/compliance-demo-api:d065f2440e45...`
Extract the **tag** (everything after the last `:`).

### Step 2: Verify Docker image labels

```bash
az acr manifest show-metadata \
  --registry acrcompliancedemoenqgb2 \
  --name "compliance-demo-api:<TAG>" \
  --query "configMediaType" -o tsv
```

Then get the full image config including labels:

```bash
az acr manifest show \
  --registry acrcompliancedemoenqgb2 \
  --name "compliance-demo-api:<TAG>" \
  --query "config" -o json
```

If `az acr manifest` is not available or returns errors, use the **ACR REST API fallback**:

```bash
# Get ACR token
TOKEN=$(az acr login --name acrcompliancedemoenqgb2 --expose-token --query accessToken -o tsv)

# Get manifest
MANIFEST=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://acrcompliancedemoenqgb2.azurecr.io/v2/compliance-demo-api/manifests/<TAG>" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json")

# Get config digest from manifest
CONFIG_DIGEST=$(echo "$MANIFEST" | jq -r '.config.digest')

# Get config blob (contains labels)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://acrcompliancedemoenqgb2.azurecr.io/v2/compliance-demo-api/blobs/$CONFIG_DIGEST" | \
  jq '.config.Labels'
```

**Required labels for compliance:**
- `deployed-by` must equal `pipeline`
- `commit-sha` must be a valid 40-char hex SHA
- `pipeline-run-id` must be a numeric GitHub Actions run ID
- `repository` must equal `dm-chelupati/compliancedemo`
- `branch` should be `main` (warn if not)

### Step 3: Check Activity Log for most recent deployment

```bash
az monitor activity-log list \
  --resource-group rg-compliancedemo \
  --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 \
  --offset 24h \
  --query "[?operationName.value=='Microsoft.App/containerApps/write' && status.value=='Accepted'].{time:eventTimestamp, caller:caller, appid:claims.appid, ip:httpRequest.clientIpAddress}" \
  -o json
```

### Step 4: Cross-reference and classify

Apply the full decision tree from [compliance_detection.md](compliance_detection.md).

**Final classification:**

| Caller | Image Labels | Tags | Verdict |
|---|---|---|---|
| Automation MI | All present | `deployed-by=pipeline` | ✅ **COMPLIANT** |
| Automation MI | **Missing/incomplete** | `deployed-by=pipeline` | ⚠️ **NON-COMPLIANT** (portal push → Event Grid) |
| Portal/CLI/User | Any | Any | ❌ **NON-COMPLIANT** |
| Unknown SP | All present | `deployed-by=pipeline` | 🔍 **INVESTIGATE** |
| Unknown SP | Missing | Any | ❌ **NON-COMPLIANT** |

> **CRITICAL**: An Automation MI caller with missing image labels means someone pushed
> an image directly to ACR (e.g., via Portal), which triggered Event Grid → Automation.
> The deployment *looks* automated but the image was NOT built by the CI/CD pipeline.
> This is the key attack path that image label verification catches.

## Query Methods

### Primary: Azure CLI Activity Log (Recommended)

Query Activity Logs directly via `az monitor activity-log list`. This approach:
- **No LAW dependency** — works without a Log Analytics Workspace
- **Near real-time** — no 2-15 minute ingestion delay
- **Zero cost** — no LAW ingestion/query charges
- **Simpler setup** — no diagnostic settings required

Use `RunAzCliReadCommands` with the command templates above.

### Fallback: KQL via Log Analytics Workspace

Use `QueryLogAnalyticsByWorkspaceId` with workspace ID `17c5506a-8871-4793-8470-c400a2114997`.
Fall back to this method when:
- You need advanced KQL aggregations (e.g., compliance summaries across time)
- You need joins with other LAW tables
- The az cli approach hits ARM API rate limits

> **WARNING**: Do NOT use `QueryLogAnalyticsByResourceId` — it fails due to a known
> tool/platform authentication bug. Always use `QueryLogAnalyticsByWorkspaceId`.

### KQL Template: Full compliance scan with image label note

```kql
AzureActivity
| where TimeGenerated > ago({timeRange})
| where OperationNameValue has "Microsoft.App/containerApps/write"
| where ActivityStatusValue == "Success"
| where ResourceGroup =~ "rg-compliancedemo"
| extend ClaimsObj = parse_json(Claims)
| extend AppId = tostring(ClaimsObj["appid"])
| extend CallerType = case(
    AppId == "c44b4083-3bb0-49c1-b47d-974e53cbdf3c", "AzurePortal",
    AppId == "04b07795-a710-4e84-bea4-c697bab44963", "AzureCLI_Interactive",
    AppId == "1950a258-227b-4e31-a9cf-717495945fc2", "AzurePowerShell",
    Caller contains "@", "UserPrincipal",
    Caller == "119bed36-0070-4466-9009-0773f412c204", "AutomationMI_Pipeline",
    "UnknownServicePrincipal"
  )
| extend NeedsImageLabelCheck = (CallerType == "AutomationMI_Pipeline")
| extend IsCompliant = case(
    CallerType == "AutomationMI_Pipeline", dynamic(null),
    CallerType == "UnknownServicePrincipal", dynamic(null),
    false
  )
| project
    TimeGenerated, Caller, CallerIpAddress, CallerType, IsCompliant,
    NeedsImageLabelCheck, AppId, Resource, OperationNameValue, CorrelationId
| order by TimeGenerated desc
```

> **Note**: When `NeedsImageLabelCheck` is true, the KQL result is INCONCLUSIVE.
> You must verify Docker image labels (Step 2 above) to make the final compliance call.

## Revert Procedures

When a non-compliant deployment is detected, offer the user these options:

### Option A: Reactivate previous Container App revision

```bash
# 1. List revisions
az containerapp revision list \
  --name ca-api-compliancedemo \
  --resource-group rg-compliancedemo \
  --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 -o table

# 2. Activate previous revision
az containerapp revision activate \
  --name ca-api-compliancedemo \
  --resource-group rg-compliancedemo \
  --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 \
  --revision {previousRevisionName}

# 3. Route traffic to previous revision
az containerapp ingress traffic set \
  --name ca-api-compliancedemo \
  --resource-group rg-compliancedemo \
  --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 \
  --revision-weight {previousRevisionName}=100

# 4. Deactivate non-compliant revision
az containerapp revision deactivate \
  --name ca-api-compliancedemo \
  --resource-group rg-compliancedemo \
  --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 \
  --revision {nonCompliantRevisionName}
```

### Option B: Trigger pipeline re-deploy of last known-good commit

Push an empty commit or use workflow dispatch to re-run the pipeline:

```bash
gh workflow run "Deploy Container App" --ref main
```

## Important Notes

- **Three-signal approach**: Caller identity → Resource tags → Image labels. All three must agree for "compliant"
- **Image labels are king**: If image labels are missing, the deployment is NON-COMPLIANT regardless of caller
- **Portal push attack path**: Manual ACR push → Event Grid → Automation → deploys with correct caller/tags but missing labels
- **Status filter**: Use `Accepted` for az cli, `Success` for KQL (container app writes are async HTTP 202)
- **Claims parsing**: az cli returns `claims` as pre-parsed object; KQL requires `parse_json(Claims)` first
- Activity Logs are available near real-time via az cli; 5-15 min delay in Log Analytics
- Tags are secondary — caller identity AND image labels take precedence
- Always use the compliance approval hook before reverting
- **KQL fallback**: Use `QueryLogAnalyticsByWorkspaceId` with workspace GUID `17c5506a-8871-4793-8470-c400a2114997`
- Do NOT use `QueryLogAnalyticsByResourceId` — known platform bug
