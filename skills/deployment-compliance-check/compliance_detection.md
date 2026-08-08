# Compliance Detection Decision Tree

## Decision Flow

For each active Container App revision and its most recent `Microsoft.App/containerApps/write` event:

### 0. Identify bootstrap-only state

Classify **NON-COMPLIANT BOOTSTRAP** when all of the following are true:

- The active image is the placeholder image or is not from the expected ACR.
- Tags contain bootstrap values such as `commit-sha=initial` or `pipeline-run-id=initial`.
- The expected ACR contains no application repository or compliant image.
- There is no prior compliant revision to reactivate.

Do not attempt a revision rollback in this state. Report remediation as blocked and require a successful approved pipeline deployment.

### 1. Classify the caller

Extract `claims.appid` with `parse_json(tostring(Claims))` in Log Analytics. If a resource-group query has no matching write, query the exact Container App resource through Azure Activity Log before treating the caller as unknown.

- appid `c44b4083-3bb0-49c1-b47d-974e53cbdf3c` -> Azure Portal -> **NON-COMPLIANT**
- appid `04b07795-a710-4e84-bea4-c697bab44963` or `04b07795-8ddb-461a-bbee-02f9e1bf7b46` -> Azure CLI -> **NON-COMPLIANT**
- appid `1950a258-227b-4e31-a9cf-717495945fc2` -> Azure PowerShell -> **NON-COMPLIANT**
- appid `872cd9fa-d31f-45e0-9eab-6e460a02d1f1` -> Visual Studio -> **NON-COMPLIANT**
- appid `0a7bdc5c-7b57-40be-9939-d4c5fc7cd417` -> Azure Mobile App -> **NON-COMPLIANT**
- Caller contains `@` -> User principal -> **NON-COMPLIANT**
- appid `__APPROVED_PIPELINE_APP_ID__` -> Approved pipeline service principal -> **go to step 2**
- Unknown service principal, or an unconfigured approved client ID -> **INVESTIGATE**

The `__APPROVED_PIPELINE_APP_ID__` placeholder is rendered by `scripts/post-deploy.sh`; it must match `claims.appid` exactly. Do not classify any service principal as approved when the rendered value is `UNCONFIGURED`.

### 2. Verify Docker image labels

Inspect the image config in ACR for ACR-hosted images, or in the source registry for public or external images. The required labels are:

- `deployed-by` = `pipeline`
- `commit-sha` = valid 40-character hexadecimal SHA
- `pipeline-run-id` = numeric GitHub Actions run ID
- `branch` = `main`
- `repository` = expected repository
- `workflow` = expected workflow name

**All labels present** + approved pipeline caller -> **COMPLIANT**
**All labels present** + unknown caller -> **INVESTIGATE**
**Any labels missing** -> **NON-COMPLIANT**

### 3. Check resource tags

Tags are secondary evidence. The workflow writes them only after the revision passes health validation, but they remain mutable and can be stale from a previous deployment.

**Caller identity and immutable image labels take precedence over tags.**

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
    AppId == "__APPROVED_PIPELINE_APP_ID__" and "__APPROVED_PIPELINE_APP_ID__" != "UNCONFIGURED", "ApprovedPipeline",
    "ServicePrincipal")
| project TimeGenerated, Caller, CallerIpAddress, CallerType, AppId, Resource, CorrelationId
| order by TimeGenerated desc
```

Set `##timeRange##` and `##resourceGroup##` for the scan. A zero-row result is not sufficient proof of no write: first confirm the workspace has raw rows, then query the exact Container App resource.

## Signal Priority

1. **Caller identity** - who made the ARM call
2. **Docker image labels** - whether the image was pipeline-built
3. **Resource tags** - mutable supporting evidence