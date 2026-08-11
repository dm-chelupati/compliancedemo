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
An approved CI/CD pipeline builds the Docker image with immutable compliance labels, pushes it to ACR, and performs the audited Container App update through an approved managed identity or service principal. An Event Grid and Automation handoff is compliant only when that path is actually provisioned and its identity is registered as an approved deployment identity; do not assume that the handoff exists.

Data Sources
Activity Logs in Log Analytics
Activity Logs flow to a Log Analytics workspace through subscription diagnostic settings. Use QueryLogAnalyticsByWorkspaceId to run KQL against the AzureActivity table.

To discover the authoritative workspace ID, first resolve the subscription diagnostic setting and then retrieve its customer ID:

az monitor diagnostic-settings subscription list --subscription <subscription-id> --query "value[?name=='activity-to-law'].workspaceId" -o tsv
az monitor log-analytics workspace show --ids <workspace-resource-id> --query customerId -o tsv

Sanity-check that the selected workspace has AzureActivity rows for the scan window before treating an empty filtered query as evidence. If the workspace has no matching Container App write rows, query the exact Container App resource with az monitor activity-log list; Activity Log routing delays or gaps must not hide a known write event.

Container App Resource Tags
Use RunAzCliReadCommands to check tags on the Container App.

Docker Image Labels in ACR
The CI/CD pipeline bakes labels into every image at build time (deployed-by, commit-sha, pipeline-run-id, branch, repository, workflow). These are immutable once pushed — they cannot be added or changed after the fact. An image pushed manually (via Portal or docker push) will NOT have these labels.

How to Detect Compliance
See compliance_detection.md for the detailed decision tree and well-known app IDs.

Step 1: Query Activity Logs
Query the AzureActivity table for Container App write operations. Extract claims.appid and Caller to identify who made the deployment. See compliance_detection.md for the KQL template.

Step 2: Classify each deployment by caller
Well-known Azure Portal / CLI / PowerShell app IDs → NON-COMPLIANT
Caller contains @ (user principal) → NON-COMPLIANT
Known pipeline managed identity → proceed to Step 3
Unknown service principal → INVESTIGATE
Caller identity ALWAYS takes precedence over tags.

Step 3: Verify Docker image labels (the tamper-proof check)
This is the most important step. Even if the caller is the pipeline's managed identity, the image itself might have been pushed to ACR manually (bypassing the CI/CD build). When that happens, an otherwise legitimate deployment mechanism can make the Activity Log look compliant even though the image was never built by GitHub Actions.

To catch this:

Get the currently running image tag from the Container App.
If the image is in the configured ACR, retrieve its image config and check for the expected labels (deployed-by=pipeline, commit-sha, pipeline-run-id, and the expected branch, repository, and workflow).
If labels are missing or invalid → NON-COMPLIANT regardless of caller.
If the running image is outside the configured ACR, record the label check as unavailable and classify it as NON-COMPLIANT. If its tags are bootstrap values such as commit-sha=initial and pipeline-run-id=initial, ACR has no application repository, and no previous revision exists, classify it as NON-COMPLIANT BOOTSTRAP. It has no safe rollback candidate.

This closes the "portal push" attack path and prevents an external bootstrap image from being mistaken for a verified pipeline artifact.

Step 4: Verify resource tags (secondary)
Compliant pipelines stamp tags like deployed-by=pipeline, pipeline-run-id, commit-sha, repository. Missing deployed-by tag is additional non-compliance evidence — but tags alone are weak because the Automation Runbook stamps them on every deploy, including ones triggered by manual ACR pushes.

Step 5: Generate compliance report
Report should include scan timestamp, time range, total/compliant/non-compliant counts, image label check results, and details of any violations.

Scheduled Scan Behavior
A scheduled scan is detection-only. Never treat the absence of interactive approval as approval, and never mutate revisions, traffic, images, or deployment workflows from the scan. If a known-good revision or compliant image exists, report the exact candidate and require explicit approval before a separately authorized remediation action. If neither exists, report remediation as blocked.

Revert Procedures
IMPORTANT: Always get user approval before any revert action.

Option A — Reactivate previous Container App revision: list revisions, activate the last known-good one, shift traffic, deactivate the non-compliant revision.

Option B — Re-run the CI/CD pipeline to redeploy the last known compliant image from the approved pipeline.

Notes
Activity Logs may take 5-15 minutes to appear in Log Analytics
claims.appid values for Portal/CLI/PowerShell are well-known Microsoft constants (see compliance_detection.md)
Caller identity is authoritative; tags can be stale from previous deploys
Docker image labels are the strongest signal — immutable once pushed to ACR
The "portal push" attack path: manual ACR push → Event Grid → Automation → looks compliant but image labels are missing
Never revert without user approval