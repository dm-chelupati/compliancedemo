---
name: deployment-compliance-check
description: >
  Detects out-of-compliance Azure Container App deployments by correlating
  Activity Log caller identity and resource tags with approved CI/CD pipelines.
  Primary method: direct Activity Log query via Azure CLI (no LAW dependency).
  Fallback method: KQL queries against a Log Analytics Workspace.
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
| Log Analytics Workspace ID (GUID) | `17c5506a-8871-4793-8470-c400a2114997` *(fallback only)* |
| Log Analytics Workspace Resource | `law-compliance-compliancedemo` *(fallback only)* |

## Query Method

### Primary: Azure CLI Activity Log (Recommended)

Query Azure Activity Logs directly via `az monitor activity-log list`. This approach:
- **No LAW dependency** — works without a Log Analytics Workspace
- **Near real-time** — no 2-15 minute ingestion delay
- **Zero cost** — no LAW ingestion/query charges
- **Simpler setup** — no diagnostic settings required

Use `RunAzCliReadCommands` with the command templates in the [Az CLI Query Templates](#az-cli-query-templates) section.

### Fallback: KQL via Log Analytics Workspace

Use `QueryLogAnalyticsByWorkspaceId` with workspace ID `17c5506a-8871-4793-8470-c400a2114997`.
Fall back to this method when:
- You need advanced KQL aggregations (e.g., compliance summaries across time)
- You need joins with other LAW tables
- The az cli approach hits ARM API rate limits

> **WARNING**: Do NOT use `QueryLogAnalyticsByResourceId` — it fails due to a known
> tool/platform authentication bug. Always use `QueryLogAnalyticsByWorkspaceId`.

To discover the workspace GUID if it changes:
```bash
az monitor log-analytics workspace show \
  --resource-group rg-compliancedemo \
  --workspace-name law-compliance-compliancedemo \
  --query customerId -o tsv
```

## Purpose

This skill checks whether Container App deployments were made through an
approved CI/CD pipeline (compliant) or through the Azure Portal / manual
CLI commands (non-compliant).

## When to use this skill

- When asked to check deployment compliance for Container Apps
- When investigating who made a configuration change
- When a deployment alert fires and you need to classify the change
- During periodic compliance scans (scheduled tasks)

## Detection strategy

Use **two signals** together for high-confidence classification:

### Signal 1: Caller identity (from Activity Log)

Query the `AzureActivity` table in Log Analytics. The `Caller` field and
the `claims.appid` inside the `Claims` column identify the source:

| claims.appid | Source | Classification |
|---|---|---|
| c44b4083-3bb0-49c1-b47d-974e53cbdf3c | Azure Portal | **Non-compliant** |
| 04b07795-a710-4e84-bea4-c697bab44963 | Azure CLI (interactive) | **Non-compliant** |
| your-pipeline-SP-client-id | GitHub Actions service principal | **Compliant** |
| (see below) | Automation Runbook MI (Event Grid deploy) | **Compliant** |
| Any other GUID (no @ in Caller) | Unknown service principal | **Investigate** |
| Any with Caller containing @ | User principal (manual) | **Non-compliant** |

> **Known compliant deployer — Automation Runbook (Event Grid pipeline):**
> - Caller (principalId): `119bed36-0070-4466-9009-0773f412c204`
> - Source: Azure Automation `auto-compliancedemo` (system-assigned MI)
> - Flow: GitHub Actions push to ACR -> Event Grid -> Automation Runbook -> az containerapp update
> - Match on: `Caller == "119bed36-0070-4466-9009-0773f412c204"` in Activity Log

### Signal 2: Resource tags (from Container App)

Compliant CI/CD pipelines stamp these tags on every deployment:

| Tag | Expected value | Meaning |
|---|---|---|
| deployed-by | pipeline | Deployment came from CI/CD |
| pipeline-run-id | GitHub Actions run_id | Links to specific workflow run |
| commit-sha | Git commit SHA | Links to specific code change |
| workflow | Workflow name | Which pipeline |
| repository | owner/repo | Source repository |

If deployed-by is missing or not pipeline, the deployment is non-compliant.

### Signal 3: Docker image labels (tamper-proof, immutable)

Docker image labels are baked in at build time and **cannot be modified** after push.
Use `az acr manifest show-metadata` or inspect via `az acr repository show` to verify them.

| Label | Value | Meaning |
|---|---|---|
| deployed-by | pipeline | Built by CI/CD |
| commit-sha | Git SHA | Exact source commit |
| pipeline-run-id | GitHub Actions run_id | Links to workflow run |
| branch | Branch name | Source branch |
| repository | owner/repo | Source repo |
| workflow | Workflow name | Which pipeline |

These labels are the **strongest compliance signal** — they prove the image was built
by the CI/CD pipeline and cannot be tampered with after the fact.

To verify: `az acr manifest show-metadata --registry acrcompliancedemoenqgb2 --name compliance-demo-api:<tag>`

## Az CLI Query Templates (Primary Method)

### Template 1: Detect recent Container App deployments

```bash
az monitor activity-log list \
  --resource-group {resourceGroup} \
  --subscription {subscriptionId} \
  --offset {timeRange} \
  --query "[?operationName.value=='Microsoft.App/containerApps/write' && status.value=='Accepted']" \
  -o json
```

> **IMPORTANT**: Use `status.value=='Accepted'` (not `Succeeded`). Container App
> write operations are async (ARM returns HTTP 202). The `Accepted` event carries
> the caller identity and claims needed for compliance classification.

### Template 2: Classification logic for az cli results

For each event in the result array, classify using these fields:

```
claims.appid  → identifies the source application
caller        → identifies the user/service principal
```

**Classification rules** (apply in order):
1. `claims.appid == "c44b4083-3bb0-49c1-b47d-974e53cbdf3c"` → Azure Portal → **NON-COMPLIANT**
2. `claims.appid == "04b07795-a710-4e84-bea4-c697bab44963"` → Azure CLI (interactive) → **NON-COMPLIANT**
3. `claims.appid == "1950a258-227b-4e31-a9cf-717495945fc2"` → Azure PowerShell → **NON-COMPLIANT**
4. `claims.appid == "872cd9fa-d31f-45e0-9eab-6e460a02d1f1"` → Visual Studio → **NON-COMPLIANT**
5. `claims.appid == "0a7bdc5c-7b57-40be-9939-d4c5fc7cd417"` → Azure Mobile App → **NON-COMPLIANT**
6. `caller` contains `@` → User principal (manual) → **NON-COMPLIANT**
7. Any other `claims.appid` with no `@` in caller → Service Principal → **COMPLIANT** (verify with tags)

> **Note**: Unlike KQL where `claims` is a JSON string requiring `parse_json()`,
> the az cli output returns `claims` as a pre-parsed object — access `claims.appid`
> directly without any JSON parsing.

### Template 3: Quick one-liner with JMESPath classification

```bash
az monitor activity-log list \
  --resource-group {resourceGroup} \
  --subscription {subscriptionId} \
  --offset {timeRange} \
  --query "[?operationName.value=='Microsoft.App/containerApps/write' && status.value=='Accepted'].{time:eventTimestamp, caller:caller, appid:claims.appid, ip:httpRequest.clientIpAddress, resource:resourceId}" \
  -o table
```

---

## KQL Query Templates (Fallback Method)

### Template 1: Detect recent Container App deployments and classify

```kql
AzureActivity
| where TimeGenerated > ago({timeRange})
| where OperationNameValue has "Microsoft.App/containerApps/write"
| where ActivityStatusValue == "Success"
| where ResourceGroup =~ "{resourceGroup}"
| extend ClaimsObj = parse_json(Claims)
| extend AppId = tostring(ClaimsObj["appid"])
| extend CallerType = case(
    AppId == "c44b4083-3bb0-49c1-b47d-974e53cbdf3c", "AzurePortal",
    AppId == "04b07795-a710-4e84-bea4-c697bab44963", "AzureCLI_Interactive",
    Caller contains "@", "UserPrincipal_Other",
    "ServicePrincipal"
  )
| extend IsCompliant = (CallerType == "ServicePrincipal")
| project
    TimeGenerated, Caller, CallerIpAddress, CallerType, IsCompliant,
    AppId, Resource, OperationNameValue, CorrelationId, Properties
| order by TimeGenerated desc
```

### Template 2: Get detailed deployment info

```kql
AzureActivity
| where CorrelationId == "{correlationId}"
| project
    TimeGenerated, OperationNameValue, ActivityStatusValue,
    Caller, CallerIpAddress, ResourceGroup, Resource,
    Claims, Properties, HTTPRequest
| order by TimeGenerated asc
```

### Template 3: Compliance summary

```kql
AzureActivity
| where TimeGenerated > ago({timeRange})
| where OperationNameValue has "Microsoft.App/containerApps/write"
| where ActivityStatusValue == "Success"
| where ResourceGroup =~ "{resourceGroup}"
| extend ClaimsObj = parse_json(Claims)
| extend AppId = tostring(ClaimsObj["appid"])
| extend CallerType = case(
    AppId == "c44b4083-3bb0-49c1-b47d-974e53cbdf3c", "AzurePortal",
    AppId == "04b07795-a710-4e84-bea4-c697bab44963", "AzureCLI_Interactive",
    Caller contains "@", "UserPrincipal_Other",
    "ServicePrincipal"
  )
| extend IsCompliant = (CallerType == "ServicePrincipal")
| summarize
    TotalDeployments = count(),
    CompliantCount = countif(IsCompliant),
    NonCompliantCount = countif(not(IsCompliant))
    by Resource
| extend ComplianceRate = round(100.0 * CompliantCount / TotalDeployments, 1)
| order by ComplianceRate asc
```

## Revert procedures

When a non-compliant deployment is detected, offer the user two revert options:

### Option A: Reactivate previous Container App revision

```bash
# 1. List revisions
az containerapp revision list --name {containerAppName} --resource-group {resourceGroup} -o table

# 2. Activate previous revision
az containerapp revision activate --name {containerAppName} --resource-group {resourceGroup} --revision {previousRevisionName}

# 3. Route traffic to previous revision
az containerapp ingress traffic set --name {containerAppName} --resource-group {resourceGroup} --revision-weight {previousRevisionName}=100

# 4. Deactivate non-compliant revision
az containerapp revision deactivate --name {containerAppName} --resource-group {resourceGroup} --revision {nonCompliantRevisionName}
```

### Option B: Trigger GitHub Actions pipeline re-run

```bash
gh run list --workflow "Deploy Container App" --status success --limit 1 --json databaseId
gh run rerun {lastSuccessfulRunId}
```

## Important notes

- **Prefer az cli** (primary) over KQL (fallback) for compliance scans — faster, no LAW dependency, zero cost
- **Status filter**: Use `Accepted` for az cli, `Success` for KQL — container app writes are async (HTTP 202)
- **Claims parsing**: az cli returns `claims` as a pre-parsed object (access `claims.appid` directly); KQL requires `parse_json(Claims)` first
- Activity Logs are available near real-time via az cli; they may take 5-15 minutes to appear in Log Analytics
- The claims.appid values for Azure Portal and CLI are well-known constants (see compliance_detection.md)
- Always confirm the pipeline SP client ID with the user
- Tags are secondary — caller identity always takes precedence
- Docker image labels are the strongest tamper-proof signal (immutable once pushed to ACR)
- The Automation MI (principalId: 119bed36-0070-4466-9009-0773f412c204) is the Event Grid deploy pipeline
- Always ask user approval via the compliance approval hook before reverting
- **KQL fallback**: Use `QueryLogAnalyticsByWorkspaceId` with workspace GUID `17c5506a-8871-4793-8470-c400a2114997`
- Do NOT use `QueryLogAnalyticsByResourceId` — known platform bug
