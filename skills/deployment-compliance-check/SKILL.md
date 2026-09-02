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
Approved deployments should use GitHub Actions with OpenID Connect to build images with immutable compliance labels, push them to the configured ACR, and directly update the configured Container App by digest. Verify the live workflow and topology before treating this path as evidence.

Do not assume an Event Grid, Automation, Logic App, or Container Apps Job deployment path exists. Verify the live topology before using it as compliance evidence or as a remediation path.

Data Sources
Activity Logs in Log Analytics
Activity Logs flow to a Log Analytics workspace through the subscription diagnostic setting. Use QueryLogAnalyticsByWorkspaceId to query the AzureActivity table.

To discover the authoritative workspace:
1. Run `az monitor diagnostic-settings subscription list --subscription <subscription-id>` and select the `activity-to-law` workspace ID.
2. Run `az monitor log-analytics workspace show --ids <workspace-resource-id> --query customerId -o tsv`.

Container App Resource Tags
Use RunAzCliReadCommands to check tags on the Container App.

Docker Image Labels in ACR
The CI/CD pipeline bakes labels into every image at build time (deployed-by, commit-sha, pipeline-run-id, branch, repository, workflow). These are immutable once pushed. An image pushed manually will not have these labels. If the running image is outside the configured ACR, image-label validation is unavailable and the image must not be treated as compliant.

How to Detect Compliance
See compliance_detection.md for the detailed decision tree and well-known app IDs.

Step 1: Query Activity Logs
Query the AzureActivity table for Container App write operations. Extract claims.appid and Caller to identify who made the deployment. See compliance_detection.md for the KQL template.

An empty targeted query is inconclusive. First verify that AzureActivity has rows for the selected time range. If the direct Activity Log shows a relevant write that predates the earliest AzureActivity row, classify the event as not covered by Log Analytics and use the direct Activity Log event as the caller-identity evidence; do not report that no deployment occurred.

If both Log Analytics and the rolling 90-day direct Activity Log query have no matching write, compare the active revision creation time to the direct-query window. When the revision predates that window, report caller identity as unavailable because of retention rather than claiming that no deployment occurred.

Step 2: Classify each deployment by caller
Well-known Azure Portal / CLI / PowerShell app IDs → NON-COMPLIANT
Caller contains @ (user principal) → NON-COMPLIANT
Known pipeline managed identity → proceed to Step 3
Unknown service principal → INVESTIGATE
Caller identity ALWAYS takes precedence over tags.

Step 3: Verify Docker image labels (the tamper-proof check)
This is the most important step. An image can be pushed to ACR outside CI/CD and later deployed by a separate identity or delivery mechanism. A legitimate-looking Activity Log caller does not prove that GitHub Actions built the image.

To catch this:

Get the currently running image reference from the Container App
Retrieve the image config from ACR and check for the expected labels (deployed-by=pipeline, commit-sha, pipeline-run-id, etc.)
If labels are missing or invalid → NON-COMPLIANT regardless of caller
Do not assume that an Event Grid, Automation, or other relay exists unless live topology proves it.

Step 4: Verify resource tags (secondary)
Compliant pipelines stamp tags like deployed-by=pipeline, pipeline-run-id, commit-sha, repository. Missing deployed-by tag is additional non-compliance evidence, but tags alone are weak because they are mutable resource metadata and may be stale or stamped by a separate deployment mechanism.

Step 5: Generate compliance report
Report should include scan timestamp, time range, total/compliant/non-compliant counts, image-label check results, and details of any violations.

Scheduled Task Scope
Scheduled scans are detection-only. They must not update, restart, reactivate, deactivate, or retag Container Apps. Report a remediation candidate only when a known-good revision or compliant ACR image exists.

Remediation Procedures
IMPORTANT: Always get explicit user approval and pass the approval hook before any revert action.

Option A — Reactivate a verified known-good Container App revision, shift traffic, then deactivate the non-compliant revision.

Option B — Re-run the approved CI/CD workflow to redeploy a verified compliant image by digest.

Bootstrap-only Condition
Classify an app as `NON-COMPLIANT BOOTSTRAP` when it runs a placeholder or external image, has bootstrap tags such as `commit-sha=initial`, has no compliant image in its configured ACR, or has no prior revision to reactivate. Do not attempt a rollback in this state; report the missing deployment prerequisites.

Notes
Activity Logs may take 5-15 minutes to appear in Log Analytics.
claims.appid values for Portal/CLI/PowerShell are well-known Microsoft constants (see compliance_detection.md).
Caller identity is authoritative; tags can be stale from previous deploys.
Docker image labels are the strongest signal when the running image is in the configured ACR.
Never revert without user approval.