---
name: deployment-compliance-check
description: |
  Checks whether Azure Container App deployments comply with the organization's CI/CD-only deployment policy. Uses three signals: Activity Log caller identity, Docker image labels (tamper-proof), and resource tags.
  QueryLogAnalyticsByWorkspaceId
tools:
  - QueryLogAnalyticsByWorkspaceId
  - GetAzCliHelp
  - RunAzCliReadCommands
  - RunAzCliWriteCommands
---

<!-- Add your skill instructions here -->
Organization Policy
All Container App deployments MUST go through the approved CI/CD pipeline (GitHub Actions).

Deployments via Azure Portal, interactive Azure CLI, or PowerShell are non-compliant.
Only service principal / managed identity deployments from the CI/CD pipeline are compliant.
Non-compliant deployments should be flagged, reported, and reverted (with user approval).
This policy ensures every production change is traceable to a code commit, reviewed via PR, and auditable through the pipeline.

How the Pipeline Works
GitHub Actions builds the Docker image with immutable compliance labels, pushes to ACR, which fires an Event Grid event. An Automation Runbook (running under a managed identity) picks up the event and updates the Container App via ARM. The key point: GitHub never authenticates to Azure AD directly — all Azure-side auth happens through managed identities inside Azure.

Data Sources
Activity Logs in Log Analytics
Activity Logs flow to the Log Analytics workspace via diagnostic settings. Use QueryLogAnalyticsByWorkspaceId to run KQL against the AzureActivity table.

To discover the workspace ID if needed, resolve the compliance workspace dynamically from the current resource group rather than assuming a fixed environment name. Example:

az resource list --resource-group <resource-group> --resource-type "Microsoft.OperationalInsights/workspaces" --query "[?starts_with(name, 'law-compliance-')].name | [0]" -o tsv
az monitor log-analytics workspace show --resource-group <resource-group> --workspace-name <resolved-workspace-name> --query customerId -o tsv

Container App Resource Tags
Use RunAzCliReadCommands to check tags on the Container App.

Docker Image Labels in ACR
The CI/CD pipeline bakes labels into every image at build time (deployed-by, commit-sha, pipeline-run-id, branch, repository, workflow). These are immutable once pushed — they cannot be added or changed after the fact. An image pushed manually (via Portal or docker push) will NOT have these labels.

How to Detect Compliance
See compliance_detection.md for the detailed decision tree and well-known app IDs.

The scan must classify every app into exactly one of these outcomes:
- COMPLIANT
- NON-COMPLIANT
- BOOTSTRAP / NOT YET EVALUABLE
- BLOCKED / UNABLE TO EVALUATE

Step 1: Query Activity Logs
Query the AzureActivity table for Container App write operations. Extract claims.appid and Caller to identify who made the deployment. See compliance_detection.md for the KQL template.

If Log Analytics returns zero rows, do not assume compliance or non-compliance. Fall back to ARM Activity Log evidence for the same time window before classifying the result.

For the ARM fallback, query the subscription Activity Log with a supported server-side filter such as event time and resource group, then filter the returned records client-side for `Microsoft.App/containerApps/write` and the target Container App resource URI. Do not rely on `operationName/value` as a server-side filter because that property is not supported by the management events endpoint.

Step 2: Classify each deployment by caller
Well-known Azure Portal / CLI / PowerShell app IDs -> NON-COMPLIANT
Caller contains @ (user principal) -> NON-COMPLIANT
Known pipeline managed identity -> proceed to Step 3
Unknown service principal -> INVESTIGATE and continue to Step 3
Caller identity ALWAYS takes precedence over tags.

Step 3: Verify Docker image labels (the tamper-proof check)
This is the most important step. Even if the caller is the pipeline's managed identity, the image itself might have been pushed to ACR manually (bypassing the CI/CD build). When that happens, Event Grid still fires, the Automation Runbook still deploys it, and the Activity Log looks legitimate - but the image was never built by GitHub Actions.

To catch this:
- Get the currently running image reference from the Container App
- Retrieve the image config from ACR and check for the expected labels (`deployed-by=pipeline`, `commit-sha`, `pipeline-run-id`, and related workflow metadata)
- If `az acr` / ARM credential discovery is unavailable, use the registry OAuth exchange flow with the agent managed identity (`https://containerregistry.azure.net/.default` -> `/oauth2/exchange` -> `/oauth2/token`) and query the repository directly
- If labels are missing or invalid -> NON-COMPLIANT regardless of caller

This closes the "portal push via Event Grid" bypass.

Bootstrap exception:
If the app is still running the seeded fallback image, the target workload repository does not exist yet in ACR (or the catalog is still empty), and the only confirmed write event is the initial bootstrap create/update, classify the app as BOOTSTRAP / NOT YET EVALUABLE. Do not treat that state as NON-COMPLIANT.

For this demo, that bootstrap create/update may appear as a user principal or Azure CLI caller because `azd up` provisions the initial Container App directly before any compliant workload image exists. If the current revision still matches the seeded fallback image and the workload repository is absent from ACR, bootstrap evidence overrides the caller classification.

If that bootstrap revision is Unhealthy or Degraded only because the seeded sample image listens on port 80 while the Container App target port is 8080, that is expected demo bootstrap behavior and not a compliance violation by itself.

Step 4: Verify resource tags (secondary)
Compliant pipelines stamp tags like `deployed-by=pipeline`, `pipeline-run-id`, `commit-sha`, and `repository`. Missing `deployed-by` is supporting evidence, but tags alone are weak because the Automation Runbook stamps them on every deploy, including ones triggered by manual ACR pushes.

Step 5: Handle incomplete platform access
If Azure discovery or query tooling is unavailable and you cannot recover enough evidence from alternate read paths, report BLOCKED / UNABLE TO EVALUATE with the exact error evidence. Never remediate based on partial data.

Treat the scan as blocked when the built-in Azure read path fails with a generic platform error (for example `Unknown error occurred.` together with required ARM scopes) and the execution shell cannot supply an alternate Azure client path (for example `bash: az: command not found`). Record both signals in the report so the next operator can distinguish an access/runtime problem from a compliance violation.

Step 6: Generate compliance report
Report should include scan timestamp, time range, total/compliant/non-compliant/bootstrap/blocked counts, image label check results, and the evidence used for every non-compliant or non-evaluable classification.

Revert Procedures
IMPORTANT: Always get user approval before any revert action.

Option A - Reactivate previous Container App revision: list revisions, activate the last known-good one, shift traffic, deactivate the non-compliant revision.

Option B - Re-run the CI/CD pipeline to redeploy the last known compliant image from the approved pipeline.

For scheduled scans, report the violation and recommended rollback path, but defer remediation until an interactive approval step is available.

Notes
Activity Logs may take 5-15 minutes to appear in Log Analytics
claims.appid values for Portal/CLI/PowerShell are well-known Microsoft constants (see compliance_detection.md); for this demo, Azure CLI writes were observed with app id `04b07795-8ddb-461a-bbee-02f9e1bf7b46`
Caller identity is authoritative; tags can be stale from previous deploys
Docker image labels are the strongest signal - immutable once pushed
The "portal push" attack path: manual ACR push -> Event Grid -> Automation -> looks compliant but image labels are missing
A zero-row Log Analytics result during bootstrap can be a monitoring gap; confirm with ARM Activity Log and ACR state before classifying
An ACR catalog response with `"repositories": null` should be treated as an empty catalog for bootstrap evaluation
Never revert without user approval