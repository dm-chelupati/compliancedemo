# Compliance Detection Decision Tree

## Decision Flow

For each Container App deployment event (Microsoft.App/containerApps/write):

### 1. Classify the caller

Extract `claims.appid` from Activity Logs with `parse_json(tostring(Claims)).appid`. `Claims` can arrive as either dynamic data or a string, so normalization is required.

- appid `c44b4083-3bb0-49c1-b47d-974e53cbdf3c` → Azure Portal → **NON-COMPLIANT**
- appid `04b07795-a710-4e84-bea4-c697bab44963` → Azure CLI → **NON-COMPLIANT**
- appid `04b07795-8ddb-461a-bbee-02f9e1bf7b46` → Azure CLI → **NON-COMPLIANT**
- appid `1950a258-227b-4e31-a9cf-717495945fc2` → Azure PowerShell → **NON-COMPLIANT**
- appid `872cd9fa-d31f-45e0-9eab-6e460a02d1f1` → Visual Studio → **NON-COMPLIANT**
- appid `0a7bdc5c-7b57-40be-9939-d4c5fc7cd417` → Azure Mobile App → **NON-COMPLIANT**
- Caller contains `@` → User principal → **NON-COMPLIANT**
- Known pipeline managed identity → **go to step 2**
- Unknown service principal → **go to step 2**

### 2. Verify Docker image labels (the tamper-proof check)

Even if the caller is the pipeline's managed identity, verify that the running image was actually built by GitHub Actions. Get the current image reference from the Container App, then retrieve the image config from ACR and look for these labels:

- `deployed-by` = `pipeline`
- `commit-sha` = valid 40-char hex SHA
- `pipeline-run-id` = numeric GitHub Actions run ID
- `branch` = should be `main`
- `repository` = should match the expected repo
- `workflow` = should match the expected workflow name

**All labels present** + known pipeline caller → **COMPLIANT**
**All labels present** + unknown caller → **INVESTIGATE**
**Any labels missing** → **NON-COMPLIANT** (image was not built by the pipeline)

This catches a manual-image-push bypass regardless of delivery topology. An Event Grid, Automation, or other relay can make an Activity Log caller appear legitimate, but none should be assumed without live evidence.

### 3. Check resource tags (secondary confirmation)

Look for `deployed-by=pipeline` and other pipeline tags on the Container App. These are the weakest signal because resource tags are mutable and can be stale or stamped by a separate deployment mechanism. Tags alone cannot prove that CI/CD built or deployed the running image.

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
let TargetResourceGroup = "##resourceGroup##";
AzureActivity
| where TimeGenerated > ago(##timeRange##)
| where OperationNameValue =~ "Microsoft.App/containerApps/write"
| where ActivityStatusValue =~ "Success"
| where ResourceGroup =~ TargetResourceGroup
| extend ClaimsObj = parse_json(tostring(Claims))
| extend AppId = tostring(ClaimsObj.appid)
| extend CallerType = case(
    AppId == "c44b4083-3bb0-49c1-b47d-974e53cbdf3c", "AzurePortal",
    AppId in ("04b07795-a710-4e84-bea4-c697bab44963", "04b07795-8ddb-461a-bbee-02f9e1bf7b46"), "AzureCLI",
    AppId == "1950a258-227b-4e31-a9cf-717495945fc2", "AzurePowerShell",
    Caller contains "@", "UserPrincipal",
    "ServicePrincipalOrManagedIdentity"
  )
| project TimeGenerated, Caller, CallerIpAddress, CallerType, AppId, ResourceId, CorrelationId
| order by TimeGenerated desc
```

Set `##timeRange##` based on context. For a historical deployment, use the largest supported window and run a target-resource Activity Log query as a fallback if Log Analytics is incomplete. Use a rolling offset rather than a fixed start time, because Activity Log rejects start times older than 90 days:

```bash
az monitor activity-log list \
  --resource-id <container-app-resource-id> \
  --offset 90d \
  --query "[?operationName.value=='Microsoft.App/containerApps/write' && status.value=='Succeeded']" \
  -o json
```

Note: When a deployment shows as ServicePrincipal (potentially compliant), you still need to verify Docker image labels to confirm the image was actually built by the pipeline. KQL alone cannot check image labels — use RunAzCliReadCommands to query ACR.

## Bootstrap-only Condition

Classify as `NON-COMPLIANT BOOTSTRAP` when the active revision runs a placeholder or external image, the configured ACR has no matching application image, tags contain bootstrap values such as `commit-sha=initial`, or there is no prior revision to reactivate. Report the missing compliant-image or revision prerequisite and do not auto-revert.

## Signal Priority

1. **Caller identity** — who made the ARM call (from Activity Log)
2. **Docker image labels** — was the image built by the pipeline (from ACR, immutable)
3. **Resource tags** — what does the Container App say (weakest, can be misleading)