---
name: deployment-compliance-check
description: >
  Detects out-of-compliance Azure Container App deployments by correlating
  Activity Log caller identity and resource tags with approved CI/CD pipelines.
  Uses KQL queries via Kusto MCP against a Log Analytics Workspace.
tools:
  - kusto_query
  - azure_cli
---

# Deployment Compliance Check

## Configuration

| Setting | Value |
|---|---|
| Log Analytics Workspace ID (GUID) | `17c5506a-8871-4793-8470-c400a2114997` |
| Log Analytics Workspace Resource | `law-compliance-compliancedemo` |
| Resource Group | `rg-compliancedemo` |
| Subscription | `cbf44432-7f45-4906-a85d-d2b14a1e8328` |
| Container App | `ca-api-compliancedemo` |

## Query Method

**Always use `QueryLogAnalyticsByWorkspaceId`** with workspace ID `17c5506a-8871-4793-8470-c400a2114997`.

> **WARNING**: Do NOT use `QueryLogAnalyticsByResourceId` — it fails due to a known
> tool/platform authentication bug (the managed identity has correct RBAC permissions
> but the tool itself does not pass them through properly). If you encounter this
> error, fall back to `QueryLogAnalyticsByWorkspaceId` using the workspace GUID above.

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
| Any other GUID (no @ in Caller) | Unknown service principal | **Investigate** |
| Any with Caller containing @ | User principal (manual) | **Non-compliant** |

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

## KQL query templates

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

- Activity Logs may take 5-15 minutes to appear in Log Analytics
- The claims.appid values for Azure Portal and CLI are well-known constants
- Always confirm the pipeline SP client ID with the user
- Tags are secondary -- caller identity always takes precedence
- Always ask user approval via the compliance approval hook before reverting
- **Query method**: Always use `QueryLogAnalyticsByWorkspaceId` with workspace GUID `17c5506a-8871-4793-8470-c400a2114997` (see [Query Method](#query-method) section)
- If `QueryLogAnalyticsByResourceId` fails, immediately retrieve the workspace GUID via `az monitor log-analytics workspace show` and switch to `QueryLogAnalyticsByWorkspaceId` — do not retry the failing tool
