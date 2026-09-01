# Compliance Detection Decision Tree

## Bootstrap-only State

If Log Analytics has no successful `Microsoft.App/containerApps/write` event that can be correlated to the active revision, first query the exact Container App resource through Azure Activity Log when the revision is less than 90 days old. Use `az monitor activity-log list --resource-id <resource-id> --offset 90d` and classify any matching successful write by its direct caller and `claims.appid`; this exact-resource result takes precedence over an empty Log Analytics query.

Only when neither source provides a matching successful write should you inspect the active image, ACR, and tags before treating the result as an unknown caller:

- The active image is a public bootstrap image instead of an image from the configured ACR.
- The configured ACR has no repository for the workload.
- Tags contain placeholder values such as `commit-sha=initial` or `pipeline-run-id=initial`.

When all three signals are present, classify the revision as **NON-COMPLIANT BOOTSTRAP**. Do not infer a caller identity when no Container App write was recorded. For revisions older than 90 days, record that direct Activity Log lookup is unavailable rather than treating its retention limit as evidence of bootstrap state. Scheduled scans report this state only; they do not modify the app.

## Decision Flow

For each Container App deployment event (Microsoft.App/containerApps/write):

### 1. Classify the caller

Extract `claims.appid` from Activity Logs (in KQL: `parse_json(tostring(Claims))["appid"]`).

- appid `c44b4083-3bb0-49c1-b47d-974e53cbdf3c` → Azure Portal → **NON-COMPLIANT**
- appid `04b07795-a710-4e84-bea4-c697bab44963` → Azure CLI → **NON-COMPLIANT**
- appid `04b07795-8ddb-461a-bbee-02f9e1bf7b46` → Azure CLI → **NON-COMPLIANT**
- appid `1950a258-227b-4e31-a9cf-717495945fc2` → Azure PowerShell → **NON-COMPLIANT**
- appid `872cd9fa-d31f-45e0-9eab-6e460a02d1f1` → Visual Studio → **NON-COMPLIANT**
- appid `0a7bdc5c-7b57-40be-9939-d4c5fc7cd417` → Azure Mobile App → **NON-COMPLIANT**
- Caller contains `@` → User principal → **NON-COMPLIANT**
- Known CI/CD managed identity or service principal → **go to step 2**
- Unknown service principal → **go to step 2**

### 2. Verify Docker image labels (the tamper-proof check)

Even if the caller is a known CI/CD identity, verify that the running image was actually built by GitHub Actions. Get the current image tag from the Container App, then retrieve the image config from ACR and look for these labels:

- `deployed-by` = `pipeline`
- `commit-sha` = valid 40-char hex SHA
- `pipeline-run-id` = numeric GitHub Actions run ID
- `branch` = should be `main`
- `repository` = should match the expected repo
- `workflow` = should match the expected workflow name

**All labels present** + known CI/CD caller → **COMPLIANT**
**All labels present** + unknown caller → **INVESTIGATE**
**Any labels missing** → **NON-COMPLIANT** (image was not built by the pipeline)

This catches image-selection bypasses: a manually pushed image can later be selected by a trusted deployment identity, making the caller and tags appear legitimate while immutable image labels expose the missing CI/CD build.

### 3. Check resource tags (secondary confirmation)

Look for `deployed-by=pipeline` and other pipeline tags on the Container App. Tags are the weakest signal because they are mutable and can be copied independently of the image build. Tags alone cannot distinguish a legitimate pipeline deployment from a manually prepared image or deployment.

**Caller identity always takes precedence over tags. Image labels always take precedence over tags.**

## Well-Known Azure Application IDs

| Application ID | Name |
|---|---|
| c44b4083-3bb0-49c1-b47d-974e53cbdf3c | Azure Portal |
| 04b07795-a710-4e84-bea4-c697bab44963 | Microsoft Azure CLI |
| 1950a258-227b-4e31-a9cf-717495945fc2 | Microsoft Azure PowerShell |
| 872cd9fa-d31f-45e0-9eab-6e460a02d1f1 | Visual Studio |
| 0a7bdc5c-7b57-40be-9939-d4c5fc7cd417 | Microsoft Azure Mobile App |

## KQL Template

```kql
AzureActivity
| where TimeGenerated > ago(##timeRange##)
| where OperationNameValue has "Microsoft.App/containerApps/write"
| where ActivityStatusValue == "Success"
| where ResourceGroup =~ "##resourceGroup##"
| extend ClaimsObj = parse_json(tostring(Claims))
| extend AppId = tostring(ClaimsObj["appid"])
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