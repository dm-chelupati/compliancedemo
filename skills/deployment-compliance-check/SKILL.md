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
Activity Logs flow to the Log Analytics workspace via diagnostic settings. Use QueryLogAnalyticsByWorkspaceId to run KQL against the AzureActivity table. Resolve the destination workspace from the subscription diagnostic setting first; resource groups can contain more than one workspace.

To discover the workspace ID:

az monitor diagnostic-settings subscription list --subscription <subscription-id> --query "value[?name=='activity-to-law'].workspaceId" -o tsv
az monitor log-analytics workspace show --ids <workspace-resource-id> --query customerId -o tsv

Container App Resource Tags
Use RunAzCliReadCommands to check tags on the Container App.

Docker Image Labels in ACR
The CI/CD pipeline bakes labels into every image at build time (deployed-by, commit-sha, pipeline-run-id, branch, repository, workflow). These are immutable once pushed — they cannot be added or changed after the fact. An image pushed manually (via Portal or docker push) will NOT have these labels.

How to Detect Compliance
See compliance_detection.md for the detailed decision tree, known app IDs, and bootstrap-only classification.

Step 1: Query Activity Logs
Query the AzureActivity table for Container App write operations. Use `parse_json(tostring(Claims))` before extracting `claims.appid`. First run a workspace and resource-group row-count query to confirm the source contains data, then query Container App writes. If Log Analytics returns no write rows, use direct Activity Log reads with `--offset 90d`; the activity-log service does not accept fixed start times older than 90 days.

Step 2: Classify each deployment by caller
Well-known Azure Portal / CLI / PowerShell app IDs → NON-COMPLIANT
Caller contains @ (user principal) → NON-COMPLIANT
Known pipeline managed identity → proceed to Step 3
Unknown service principal → INVESTIGATE
Caller identity ALWAYS takes precedence over tags.

Step 3: Verify Docker image labels (the tamper-proof check)
This is the most important step. Even if the caller is the pipeline's managed identity, the image itself might have been pushed to ACR manually (bypassing the CI/CD build). When that happens, Event Grid still fires, the Automation Runbook still deploys it, and the Activity Log looks legitimate — but the image was never built by GitHub Actions.

To catch this:

Get the currently running image tag from the Container App
If the image belongs to the configured ACR, retrieve its config and check for the expected labels (deployed-by=pipeline, commit-sha, pipeline-run-id, branch, repository, workflow)
If labels are missing or invalid → NON-COMPLIANT regardless of caller
If the image is external to the configured ACR, it cannot meet the approved ACR-label requirement; classify it as NON-COMPLIANT unless the bootstrap-only rule below applies
This closes the "portal push via Event Grid" bypass.

Step 4: Verify resource tags (secondary)
Compliant pipelines stamp tags like deployed-by=pipeline, pipeline-run-id, commit-sha, repository. Missing deployed-by tag is additional non-compliance evidence — but tags alone are weak because the Automation Runbook stamps them on every deploy, including ones triggered by manual ACR pushes.

Step 5: Identify bootstrap-only state
Classify the app as NON-COMPLIANT BOOTSTRAP when it is still on the public placeholder image, pipeline tags are `initial`, the configured ACR contains no application repository, and no prior compliant revision exists. This is not a revert candidate because neither Option A nor Option B has a safe target.

Step 6: Generate compliance report
Report the scan timestamp in UTC, audit-window duration, scoped Container App count, and counts by classification. For each app, include its active revision and image, caller result (or `unavailable: activity-log retention`), configured ACR and image-label result, relevant deployment tags, verified compliant rollback target (if any), classification, and required remediation. If the Activity Log query finds no writes, include the scoped workspace row-count sanity result; do not describe zero write rows as proof that no deployment ever occurred.

Scheduled Task Execution
Scheduled compliance scans are detection-only. Report the classification and required remediation, but do not modify a Container App, reactivate or deactivate revisions, or dispatch a pipeline. Reverts require an interactive investigation, a verified compliant target, and a successful compliance approval hook.

Revert Procedures
IMPORTANT: Invoke the configured compliance approval hook before any revert action, and do not change a resource unless a known-good revision or approved pipeline image has been verified.

Option A — Reactivate previous Container App revision: list revisions, verify the selected revision used a compliant image, activate it, shift traffic, then deactivate the non-compliant revision.

Option B — Re-run the CI/CD pipeline to redeploy the last known compliant image from the approved pipeline.

If no prior compliant revision exists and the configured ACR has no compliant application image, report NON-COMPLIANT BOOTSTRAP. Do not substitute a public image, manually update the Container App, or dispatch a workflow targeting a different registry.

Notes
Activity Logs may take 5-15 minutes to appear in Log Analytics
claims.appid values for Portal/CLI/PowerShell are well-known Microsoft constants (see compliance_detection.md)
Caller identity is authoritative; tags can be stale from previous deploys
Docker image labels are the strongest signal — immutable once pushed to ACR
The "portal push" attack path: manual ACR push → Event Grid → Automation → looks compliant but image labels are missing
Never revert without the required approval hook