# Compliance Detection Decision Tree

## Decision Flow

For each Container App deployment event (Microsoft.App/containerApps/write):

### 1. Classify the caller

Extract `claims.appid` from Activity Logs (in KQL: `tostring(parse_json(tostring(Claims)).appid)`).

- appid `c44b4083-3bb0-49c1-b47d-974e53cbdf3c` → Azure Portal → **NON-COMPLIANT**
- appid `04b07795-a710-4e84-bea4-c697bab44963` or `04b07795-8ddb-461a-bbee-02f9e1bf7b46` → Azure CLI → **NON-COMPLIANT**
- appid `1950a258-227b-4e31-a9cf-717495945fc2` → Azure PowerShell → **NON-COMPLIANT**
- appid `872cd9fa-d31f-45e0-9eab-6e460a02d1f1` → Visual Studio → **NON-COMPLIANT**
- appid `0a7bdc5c-7b57-40be-9939-d4c5fc7cd417` → Azure Mobile App → **NON-COMPLIANT**
- Caller contains `@` → User principal → **NON-COMPLIANT**
- Known pipeline managed identity → **go to step 2**
- Unknown service principal → **go to step 2**

### 2. Verify Docker image labels (the tamper-proof check)

Even if the caller is the pipeline's managed identity, verify that the running image was actually built by GitHub Actions. Get the current image tag from the Container App, then retrieve the image config from ACR and look for these labels:

- `deployed-by` = `pipeline`
- `commit-sha` = valid 40-char hex SHA
- `pipeline-run-id` = numeric GitHub Actions run ID
- `branch` = should be `main`
- `repository` = should match the expected repo
- `workflow` = should match the expected workflow name

**All labels present** + known pipeline caller → **COMPLIANT**
**All labels present** + unknown caller → **INVESTIGATE**
**Any labels missing** → **NON-COMPLIANT** (image was not built by the pipeline)

This catches the portal-push bypass: someone pushes an image to ACR manually → Event Grid fires → Automation deploys it → caller and tags look fine, but image labels are missing because GitHub Actions didn't build it.

### 3. Check resource tags (secondary confirmation)

Look for `deployed-by=pipeline` and other pipeline tags on the Container App. These are the weakest signal because the Automation Runbook stamps them on every deploy regardless of how the image got into ACR. Tags alone cannot distinguish a legitimate pipeline deploy from a portal-push-via-Event-Grid deploy.

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
| where OperationNameValue has "Microsoft.App/containerApps/write"
| where ActivityStatusValue == "Success"
| where ResourceGroup =~ "<resource-group>"
| extend ClaimsObj = parse_json(tostring(Claims))
| extend AppId = tostring(ClaimsObj.appid)
| extend CallerType = case(
    AppId == "c44b4083-3bb0-49c1-b47d-974e53cbdf3c", "AzurePortal",
    AppId in ("04b07795-a710-4e84-bea4-c697bab44963", "04b07795-8ddb-461a-bbee-02f9e1bf7b46"), "AzureCLI",
    AppId == "1950a258-227b-4e31-a9cf-717495945fc2", "AzurePowerShell",
    Caller contains "@", "UserPrincipal",
    "ServicePrincipal"
  )
| extend IsCompliant = (CallerType == "ServicePrincipal")
| project TimeGenerated, Caller, CallerIpAddress, CallerType, IsCompliant, AppId, Resource, CorrelationId
| order by TimeGenerated desc
```

Set `##timeRange##` based on context (30m, 1h, 4h, 24h).

### Direct Activity Log fallback

If a correctly scoped Log Analytics query has no Container App write, query the exact resource directly before falling back to `systemData`:

```sh
az monitor activity-log list --resource-id <container-app-resource-id> --offset 90d --subscription <subscription-id> --query "[?operationName.value=='Microsoft.App/containerApps/write' && status.value=='Succeeded'].{time:eventTimestamp,caller:caller,claims:claims,correlationId:correlationId}" -o json
```

A successful direct event is authoritative caller evidence for that Container App. A zero-row Log Analytics query can reflect diagnostic ingestion or retention gaps and cannot prove no deployment occurred. Parse `claims.appid` from the returned `claims` object using the same caller classification rules.

Note: When a deployment shows as ServicePrincipal (potentially compliant), you still need to verify Docker image labels to confirm the image was actually built by the pipeline. If no caller event is available from either Log Analytics or direct Activity Log, inspect `systemData`: a `createdBy` or `lastModifiedBy` value containing `@` with the corresponding `*ByType` equal to `User` is non-compliant fallback evidence when its timestamp matches the active revision creation or last modification. It cannot establish CI/CD compliance. KQL alone cannot check image labels — use RunAzCliReadCommands to query ACR.

## Bootstrap-Only Environments

Classify the app as **NON-COMPLIANT BOOTSTRAP** when all of the following apply:

- The active revision uses a placeholder or external image, or the expected ACR repository is absent.
- No image labels can establish a pipeline build.
- No earlier healthy revision exists.
- Activity Log evidence is unavailable, or timestamp-correlated `systemData` identifies a user deployment.

Report the violation and failed revision state, but do not reactivate, deactivate, or retarget traffic. There is no known-good rollback target; the remedy is a new approved pipeline deployment.

## Signal Priority

1. **Caller identity** — who made the ARM call (from Activity Log)
2. **Docker image labels** — was the image built by the pipeline (from ACR, immutable)
3. **Timestamp-correlated systemData** — fallback non-compliance evidence only when Activity Log evidence is unavailable
4. **Resource tags** — what does the Container App say (weakest, can be misleading)