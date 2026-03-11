# Compliance Detection Decision Tree

## Decision flow

Activity Log event (Microsoft.App/containerApps/write, Success):

1. Extract claims.appid from Claims column
2. appid == c44b4083-3bb0-49c1-b47d-974e53cbdf3c -> Azure Portal -> NON-COMPLIANT
3. appid == 04b07795-a710-4e84-bea4-c697bab44963 -> Azure CLI -> NON-COMPLIANT
4. Caller contains @ -> User principal -> NON-COMPLIANT
5. appid matches approved CI/CD SP -> GitHub Actions -> COMPLIANT (verify with tags)
6. Unknown service principal -> INVESTIGATE

## Well-known Azure application IDs

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
