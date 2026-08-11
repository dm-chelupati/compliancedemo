# Compliance Detection Decision Tree

## Decision Flow

For each Container App deployment event (`Microsoft.App/containerApps/write`):

### 1. Classify the caller

Normalize `Claims` before parsing it: `parse_json(tostring(Claims))`. Classify these callers as **NON-COMPLIANT**:

- Azure Portal app ID `c44b4083-3bb0-49c1-b47d-974e53cbdf3c`
- Azure CLI app IDs `04b07795-a710-4e84-bea4-c697bab44963` and `04b07795-8ddb-461a-bbee-02f9e1bf7b46`
- Azure PowerShell app ID `1950a258-227b-4e31-a9cf-717495945fc2`
- Visual Studio app ID `872cd9fa-d31f-45e0-9eab-6e460a02d1f1`
- Azure Mobile App app ID `0a7bdc5c-7b57-40be-9939-d4c5fc7cd417`
- Any `Caller` containing `@`, because it is a user principal.

A known pipeline managed identity is eligible for the image-label check. An unknown service principal is **INVESTIGATE** unless the label check and approved-identity mapping both establish compliance. A service principal is not compliant solely because it is a service principal.

### 2. Verify Docker image labels (the tamper-proof check)

For an image in the configured ACR, inspect its image config for these labels:

- `deployed-by` = `pipeline`
- `commit-sha` = valid 40-character hexadecimal SHA
- `pipeline-run-id` = numeric GitHub Actions run ID
- `branch` = `main`
- `repository` = expected repository
- `workflow` = expected workflow

**All labels present** plus a known pipeline identity → **COMPLIANT**.

**All labels present** plus an unrecognized service principal → **INVESTIGATE**.

**Any labels missing or invalid** → **NON-COMPLIANT**.

If the running image is outside the configured ACR, label verification is unavailable and the deployment is **NON-COMPLIANT**. If that image also has `commit-sha=initial` and `pipeline-run-id=initial`, ACR has no application repository, and there is no previous revision, classify it as **NON-COMPLIANT BOOTSTRAP**. Do not identify a rollback candidate that does not exist.

### 3. Check resource tags (secondary confirmation)

Look for `deployed-by=pipeline` and other pipeline tags on the Container App. Tags are weak evidence because they may be stale or stamped by an intermediary regardless of how the image reached ACR.

**Caller identity and immutable image labels always take precedence over tags.**

## Well-Known Azure Application IDs

| Application ID | Name |
|---|---|
| c44b4083-3bb0-49c1-b47d-974e53cbdf3c | Azure Portal |
| 04b07795-a710-4e84-bea4-c697bab44963 | Microsoft Azure CLI |
| 04b07795-8ddb-461a-bbee-02f9e1bf7b46 | Microsoft Azure CLI |
| 1950a258-227b-4e31-a9cf-717495945fc2 | Microsoft Azure PowerShell |
| 872cd9fa-d31f-45e0-9eab-6e460a02d1f1 | Visual Studio |
| 0a7bdc5c-7b57-40be-9939-d4c5fc7cd417 | Microsoft Azure Mobile App |

## KQL Template

```kql
AzureActivity
| where TimeGenerated > ago(##timeRange##)
| where OperationNameValue =~ "MICROSOFT.APP/CONTAINERAPPS/WRITE"
| where ActivityStatusValue =~ "Success"
| where ResourceGroup =~ "##resourceGroup##"
| extend ClaimsObj = parse_json(tostring(Claims))
| extend AppId = tostring(ClaimsObj.appid)
| extend CallerType = case(
    AppId == "c44b4083-3bb0-49c1-b47d-974e53cbdf3c", "AzurePortal",
    AppId in ("04b07795-a710-4e84-bea4-c697bab44963", "04b07795-8ddb-461a-bbee-02f9e1bf7b46"), "AzureCLI",
    AppId == "1950a258-227b-4e31-a9cf-717495945fc2", "AzurePowerShell",
    Caller contains "@", "UserPrincipal",
    "ServicePrincipal"
  )
| extend CallerAssessment = case(
    CallerType in ("AzurePortal", "AzureCLI", "AzurePowerShell", "UserPrincipal"), "NON-COMPLIANT",
    "REQUIRES_IMAGE_AND_IDENTITY_VALIDATION"
  )
| project TimeGenerated, Caller, CallerIpAddress, CallerType, CallerAssessment, AppId, Resource, CorrelationId
| order by TimeGenerated desc
```

Set `##timeRange##` based on the scan context, and replace `##resourceGroup##` with the actual resource group.

Before relying on an empty result, run a summary query to verify that the workspace ingests `AzureActivity` rows for the same time range. Scope the entire summary to the target resource group; global Container App write counts can include unrelated apps and must not be compared with a resource-group-scoped detail query.

```kql
AzureActivity
| where TimeGenerated > ago(##timeRange##)
| where ResourceGroup =~ "##resourceGroup##"
| summarize totalRows=count(), latestRow=max(TimeGenerated), containerAppWrites=countif(OperationNameValue =~ "MICROSOFT.APP/CONTAINERAPPS/WRITE"), successfulContainerAppWrites=countif(OperationNameValue =~ "MICROSOFT.APP/CONTAINERAPPS/WRITE" and ActivityStatusValue =~ "Success")
```

If the selected workspace has no matching write records, query the exact Container App resource with `az monitor activity-log list` and use that direct event as caller evidence. KQL alone cannot verify image labels; use ACR only when the running image is actually present there.

## Signal Priority

1. **Caller identity** — who made the ARM call (Activity Log)
2. **Docker image labels** — whether the artifact was built by the pipeline (ACR, immutable)
3. **Resource tags** — what the Container App says (weakest, can be misleading)