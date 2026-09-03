# Compliance Detection Decision Tree

## Decision Flow

Start with the active Container App revision and then evaluate the corresponding `Microsoft.App/containerApps/write` event when it is still within retention.

### 0. Detect bootstrap-only state

Classify **NON-COMPLIANT BOOTSTRAP** when all of the following are true:

- The active image is the known public bootstrap placeholder or is not present in the configured ACR.
- Pipeline tags are initial or otherwise do not identify a real commit/run.
- The configured ACR has no compliant application image.
- There is no previous known-good revision to reactivate.

Caller information may be unavailable after retention expires. That is a missing prerequisite, not compliant evidence, and does not block the bootstrap classification.

### 1. Classify the caller

Extract `claims.appid` safely from Activity Logs: `extend ClaimsObj = parse_json(tostring(Claims)) | extend AppId = tostring(ClaimsObj.appid)`.

- appid `c44b4083-3bb0-49c1-b47d-974e53cbdf3c` → Azure Portal → **NON-COMPLIANT**
- appid `04b07795-a710-4e84-bea4-c697bab44963` or `04b07795-8ddb-461a-bbee-02f9e1bf7b46` → Azure CLI → **NON-COMPLIANT**
- appid `1950a258-227b-4e31-a9cf-717495945fc2` → Azure PowerShell → **NON-COMPLIANT**
- appid `872cd9fa-d31f-45e0-9eab-6e460a02d1f1` → Visual Studio → **NON-COMPLIANT**
- appid `0a7bdc5c-7b57-40be-9939-d4c5fc7cd417` → Azure Mobile App → **NON-COMPLIANT**
- Caller contains `@` → User principal → **NON-COMPLIANT**
- Known pipeline managed identity → **go to step 2**
- Unknown service principal → **go to step 2**
- No event available because of retention → report caller as unavailable and continue with current-state evidence

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
**Any labels missing on an ACR image** → **NON-COMPLIANT** (image was not built by the pipeline)
**Public/bootstrap image or no matching ACR image** → evaluate the bootstrap criteria in step 0; otherwise **INVESTIGATE**

This catches the manual-image bypass: someone pushes an image to ACR outside CI/CD, then an approved Azure deployment path updates the app. Caller and tags can look legitimate, but immutable image labels are missing.

### 3. Check resource tags (secondary confirmation)

Look for `deployed-by=pipeline` and other pipeline tags on the Container App. These are the weakest signal because they can be stale or copied from an earlier deploy. Tags alone cannot distinguish a legitimate pipeline deploy from a manual image deployment.

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
| where tolower(OperationNameValue) == "microsoft.app/containerapps/write"
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
| extend IsCompliant = (CallerType == "ServicePrincipal")
| project TimeGenerated, Caller, CallerIpAddress, CallerType, IsCompliant, AppId, ResourceId, CorrelationId
| order by TimeGenerated desc
```

Set `##timeRange##` based on context (30m, 1h, 4h, 24h).

Note: When a deployment shows as ServicePrincipal (potentially compliant), you still need to verify Docker image labels to confirm the image was actually built by the pipeline. KQL alone cannot check image labels — use RunAzCliReadCommands to query ACR.

## Signal Priority

1. **Caller identity** — who made the ARM call (from Activity Log)
2. **Docker image labels** — was the image built by the pipeline (from ACR, immutable)
3. **Resource tags** — what does the Container App say (weakest, can be misleading)