# Compliance Detection Decision Tree

## Query execution

### Primary: Az CLI (recommended)

```bash
az monitor activity-log list \
  --resource-group rg-compliancedemo \
  --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 \
  --offset {timeRange} \
  --query "[?operationName.value=='Microsoft.App/containerApps/write' && status.value=='Accepted']" \
  -o json
```

Access `claims.appid` directly from the result — no JSON parsing needed.

### Fallback: KQL via Log Analytics

Use `QueryLogAnalyticsByWorkspaceId` with workspace ID `17c5506a-8871-4793-8470-c400a2114997`.
Do NOT use `QueryLogAnalyticsByResourceId` (known platform bug — see SKILL.md for details).
In KQL, use `parse_json(Claims)["appid"]` and filter on `ActivityStatusValue == "Success"`.

## Decision flow

Activity Log event (Microsoft.App/containerApps/write):
- **Az CLI**: filter on `status.value == 'Accepted'`
- **KQL**: filter on `ActivityStatusValue == 'Success'`

1. Extract `claims.appid` (az cli: direct access; KQL: `parse_json(Claims)["appid"]`)
2. appid == b2eb3f37-8a6e-4cf7-b583-a703da1fe44d -> GitHub Actions UAMI -> **COMPLIANT** (verify with tags)
3. appid == c44b4083-3bb0-49c1-b47d-974e53cbdf3c -> Azure Portal -> NON-COMPLIANT
4. appid == 04b07795-a710-4e84-bea4-c697bab44963 -> Azure CLI -> NON-COMPLIANT
5. appid == 1950a258-227b-4e31-a9cf-717495945fc2 -> Azure PowerShell -> NON-COMPLIANT
6. appid == 872cd9fa-d31f-45e0-9eab-6e460a02d1f1 -> Visual Studio -> NON-COMPLIANT
7. appid == 0a7bdc5c-7b57-40be-9939-d4c5fc7cd417 -> Azure Mobile App -> NON-COMPLIANT
8. Caller contains @ -> User principal -> NON-COMPLIANT
9. Unknown service principal -> INVESTIGATE

## Approved CI/CD application IDs

| Application ID | Identity | Classification |
|---|---|---|
| b2eb3f37-8a6e-4cf7-b583-a703da1fe44d | `id-compliancedemo-deploy` (GitHub Actions UAMI) | **COMPLIANT** |

This is the User-Assigned Managed Identity with OIDC federated credentials for the GitHub Actions pipeline.
It deploys directly to the Container App — its client ID appears as `claims.appid` in the Activity Log.

## Well-known Azure application IDs (non-compliant)

| Application ID | Application name |
|---|---|
| c44b4083-3bb0-49c1-b47d-974e53cbdf3c | Azure Portal |
| 04b07795-a710-4e84-bea4-c697bab44963 | Microsoft Azure CLI |
| 1950a258-227b-4e31-a9cf-717495945fc2 | Microsoft Azure PowerShell |
| 872cd9fa-d31f-45e0-9eab-6e460a02d1f1 | Visual Studio |
| 0a7bdc5c-7b57-40be-9939-d4c5fc7cd417 | Microsoft Azure Mobile App |

Any of these indicates manual/interactive change -> non-compliant.

## Tag-based verification

Check Container App tags:

```bash
az containerapp show --name {name} --resource-group {rg} --query tags -o json
```

Expected compliant tags:
- deployed-by: pipeline
- deployment-method: github-actions
- pipeline-run-id: GitHub Actions run ID
- commit-sha: Git commit SHA
- workflow: Workflow name
- repository: owner/repo
- branch: Branch name

**Key rule**: Caller identity ALWAYS takes precedence over tags.
Tags are secondary confirmation only.

## Tag inconsistency matrix

| Caller says | Tags say | Verdict |
|---|---|---|
| ServicePrincipal | deployed-by=pipeline | Compliant |
| AzurePortal | Tags from last deploy | Non-compliant (stale tags) |
| AzurePortal | deployed-by=pipeline | Non-compliant (caller overrides) |
| Unknown SP | No pipeline tags | Investigate |
