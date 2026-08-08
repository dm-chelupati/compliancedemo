# Compliance Detection Decision Tree

## Decision Flow

For each Container App deployment event (Microsoft.App/containerApps/write):

### 1. Classify the caller

Extract `claims.appid` with `parse_json(tostring(Claims))` in Log Analytics. If the resource-group-scoped KQL query has no result, query the exact Container App resource through Azure Activity Log before treating the caller as unknown.

- appid `c44b4083-3bb0-49c1-b47d-974e53cbdf3c` -> Azure Portal -> **NON-COMPLIANT**
- appid `04b07795-a710-4e84-bea4-c697bab44963` or `04b07795-8ddb-461a-bbee-02f9e1bf7b46` -> Azure CLI -> **NON-COMPLIANT**
- appid `1950a258-227b-4e31-a9cf-717495945fc2` -> Azure PowerShell -> **NON-COMPLIANT**
- appid `872cd9fa-d31f-45e0-9eab-6e460a02d1f1` -> Visual Studio -> **NON-COMPLIANT**
- appid `0a7bdc5c-7b57-40be-9939-d4c5fc7cd417` -> Azure Mobile App -> **NON-COMPLIANT**
- Caller contains `@` -> User principal -> **NON-COMPLIANT**
- Approved pipeline service principal or managed identity -> **go to step 2**
- Unknown service principal -> **go to step 2**

### 2. Verify Docker image labels (the tamper-proof check)

Verify that the running image was built by GitHub Actions. Retrieve an ACR-hosted image config from ACR, or retrieve the config from the source registry for a public or external image. Check for these labels:

- `deployed-by` = `pipeline`
- `commit-sha` = valid 40-char hex SHA
- `pipeline-run-id` = numeric GitHub Actions run ID
- `branch` = `main`
- `repository` = expected repository
- `workflow` = expected workflow name

**All labels present** + approved pipeline caller -> **COMPLIANT**
**All labels present** + unknown caller -> **INVESTIGATE**
**Any labels missing** -> **NON-COMPLIANT**

### 3. Check resource tags (secondary confirmation)

The GitHub Actions deployment helper stamps pipeline tags only after the new revision and its health endpoint pass validation. Tags are mutable and can be stale, so they cannot prove the caller or image provenance.

**Caller identity always takes precedence over tags. Image labels always take precedence over tags.**

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
| where OperationNameValue =~ "Microsoft.App/containerApps/write"
| where ActivityStatusValue =~ "Success"
| where ResourceGroup =~ "##resourceGroup##"
| extend ClaimsObj = parse_json(tostring(Claims))
| extend AppId = tostring(ClaimsObj.appid)
| extend CallerType = case(
    AppId == "c44b4083-3bb0-49c1-b47d-974e53cbdf3c", "AzurePortal",
    AppId == "04b07795-a710-4e84-bea4-c697bab44963" or AppId == "04b07795-8ddb-461a-bbee-02f9e1bf7b46", "AzureCLI",
    AppId == "1950a258-227b-4e31-a9cf-717495945fc2", "AzurePowerShell",
    AppId == "872cd9fa-d31f-45e0-9eab-6e460a02d1f1", "VisualStudio",
    AppId == "0a7bdc5c-7b57-40be-9939-d4c5fc7cd417", "AzureMobileApp",
    Caller contains "@", "UserPrincipal",
    "ServicePrincipal")
| project TimeGenerated, Caller, CallerIpAddress, CallerType, AppId, Resource, CorrelationId
| order by TimeGenerated desc
```

Set `##timeRange##` and `##resourceGroup##` for the scan. For a scheduled scan, use a window that includes the active revision creation time.

A zero-row KQL result is not proof that the Container App has no write event. First verify that raw AzureActivity rows exist in the selected workspace, then query the exact Container App resource through Azure Activity Log if the resource-group-scoped query remains empty.

When a deployment shows as a service principal, verify the image labels before treating it as compliant. KQL cannot establish image provenance.

## Signal Priority

1. **Caller identity** — who made the ARM call (from Activity Log)
2. **Docker image labels** — was the image built by the pipeline (from ACR, immutable)
3. **Resource tags** — what does the Container App say (weakest, can be misleading)