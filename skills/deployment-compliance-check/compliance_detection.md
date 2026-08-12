# Compliance Detection Decision Tree

## Decision Flow

For each Container App, inspect the active revision before interpreting deployment events.

### 0. Identify bootstrap-only state

Classify the app as **NON-COMPLIANT BOOTSTRAP** when all of the following are true:

- The active image is the public placeholder `mcr.microsoft.com/azuredocs/containerapps-helloworld:latest`.
- Tags contain `commit-sha=initial` and `pipeline-run-id=initial`.
- The configured ACR has no approved application repository or image.
- Revision history has no prior healthy revision.

Report this state and require a compliant forward deployment. Do not attempt a rollback because there is no verified rollback target.

### 1. Classify the caller

Extract `claims.appid` with `parse_json(tostring(Claims))` because `Claims` can be dynamically typed in Log Analytics.

- appid `c44b4083-3bb0-49c1-b47d-974e53cbdf3c` -> Azure Portal -> **NON-COMPLIANT**
- appid `04b07795-a710-4e84-bea4-c697bab44963` -> Azure CLI -> **NON-COMPLIANT**
- appid `04b07795-8ddb-461a-bbee-02f9e1bf7b46` -> Azure CLI -> **NON-COMPLIANT**
- appid `1950a258-227b-4e31-a9cf-717495945fc2` -> Azure PowerShell -> **NON-COMPLIANT**
- appid `872cd9fa-d31f-45e0-9eab-6e460a02d1f1` -> Visual Studio -> **NON-COMPLIANT**
- appid `0a7bdc5c-7b57-40be-9939-d4c5fc7cd417` -> Azure Mobile App -> **NON-COMPLIANT**
- Caller contains `@` -> User principal -> **NON-COMPLIANT**
- Approved CI/CD service principal or managed identity -> go to step 2
- Unknown service principal -> go to step 2 and classify as **INVESTIGATE** unless the identity is verified

### 2. Verify Docker image labels

For an ACR-hosted active image, retrieve the image config and require these labels:

- `deployed-by` = `pipeline`
- `commit-sha` = valid 40-character hexadecimal SHA
- `pipeline-run-id` = numeric GitHub Actions run ID
- `branch` = `main`
- `repository` = expected repository
- `workflow` = expected workflow name

**All labels present** + approved CI/CD caller -> **COMPLIANT**

**All labels present** + unknown caller -> **INVESTIGATE**

**Any labels missing or invalid** -> **NON-COMPLIANT**

The repository's approved workflow directly runs `az containerapp update`; a manual ACR push does not deploy by itself. Labels are immutable after push but are not a substitute for caller validation or signed provenance.

### 3. Check resource tags

Check for `deployed-by=pipeline` and other traceability tags. Tags are secondary confirmation only: a user with Container App write access can set them, so matching tags cannot prove compliance.

**Caller identity and image evidence always take precedence over tags.**

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
    AppId in ("04b07795-a710-4e84-bea4-c697bab44963", "04b07795-8ddb-461a-bbee-02f9e1bf7b46"), "AzureCLI",
    AppId == "1950a258-227b-4e31-a9cf-717495945fc2", "AzurePowerShell",
    Caller contains "@", "UserPrincipal",
    "ServicePrincipal"
  )
| project TimeGenerated, Caller, CallerIpAddress, CallerType, AppId, Resource, CorrelationId
| order by TimeGenerated desc
```

Set `##timeRange##` and `##resourceGroup##` for the target. First run a resource-group-scoped row-count query to verify ingestion. If that scope has activity rows but no Container App write, verify the exact app with `az monitor activity-log list --resource-id <container-app-id>`; do not treat an empty KQL result as proof that no write occurred.

## Signal Priority

1. **Caller identity** - who made the ARM call.
2. **Docker image labels** - whether the ACR image has the expected CI metadata.
3. **Resource tags** - supporting metadata only.