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
All Container App deployments MUST use an approved CI/CD deployment path. Deployments via Azure Portal, interactive Azure CLI, or PowerShell are non-compliant.
Only a verified pipeline service principal or managed identity plus a pipeline-built image is compliant.
Non-compliant deployments must be flagged and reported. Any recovery action requires a verified recovery target and the approval hook.

How the Pipeline Works
The shipped GitHub workflow builds and pushes an image to ACR, but it does not update the Container App. The current infrastructure provisions no Event Grid-to-Automation deployment component. Do not treat an ACR push as a deployment: verify an approved deployment component and its identity before classifying a revision as compliant.

Data Sources
Activity Logs in Log Analytics
Activity Logs flow to the Log Analytics workspace via diagnostic settings. Use QueryLogAnalyticsByWorkspaceId to run KQL against the AzureActivity table, then use a direct resource-scoped Activity Log query if Log Analytics is delayed or cannot be correlated to the app.

To discover the workspace ID, resolve the subscription diagnostic setting named `activity-to-law`, then obtain the referenced workspace `customerId`.
Container App Resource Tags
Use RunAzCliReadCommands to check tags on the Container App. Tags are secondary evidence only.

Docker Image Labels in ACR
The CI/CD pipeline bakes immutable labels into ACR images: `deployed-by`, `commit-sha`, `pipeline-run-id`, `branch`, `repository`, and `workflow`. Inspect labels only for images hosted in the expected ACR. A placeholder or public image cannot provide pipeline-label evidence.

How to Detect Compliance
See compliance_detection.md for the detailed decision tree, caller IDs, and direct Activity Log fallback.

Step 1: Query Activity Logs
Query the AzureActivity table for Container App write operations. Extract claims.appid and Caller to identify who made the deployment. See compliance_detection.md for the KQL template.

Step 2: Classify each deployment by caller
Well-known Azure Portal / CLI / PowerShell app IDs → NON-COMPLIANT
Caller contains @ (user principal) → NON-COMPLIANT
Known pipeline managed identity → proceed to Step 3
Unknown service principal → INVESTIGATE
Caller identity ALWAYS takes precedence over tags.

Step 3: Verify Docker image labels (the tamper-proof check)
For a running image in the expected ACR, retrieve the image config and validate `deployed-by=pipeline`, a 40-character `commit-sha`, numeric `pipeline-run-id`, `branch=main`, expected repository, and expected workflow. Missing or invalid labels are non-compliant regardless of caller.

Do not attempt a label check for a placeholder or public image. If that image is accompanied by `initial` tags, no expected ACR repository, and no known-good prior revision, classify it as `NON-COMPLIANT BOOTSTRAP` rather than a revert candidate.

Step 4: Verify resource tags (secondary)
Compliant pipelines stamp tags such as `deployed-by=pipeline`, `pipeline-run-id`, `commit-sha`, and `repository`. Tags alone are weak and can remain `initial` or be written by an updater for a non-pipeline image.

Step 5: Generate compliance report
Report the scan timestamp, lookback window, activity-log source, total/compliant/non-compliant/investigate counts, image-label result, tags, and per-app evidence.

Scheduled Scan Behavior
Scheduled scans are detection-only. Do not activate/deactivate revisions, change traffic, update a Container App, or re-run a deployment workflow.

Manual Recovery
The approval hook and a verified recovery target are mandatory: either a known-good prior revision or a known-compliant image in the expected ACR. Without one, report the blocker and repair the approved deployment path first.

Notes
- Activity Logs may take 5-15 minutes to appear in Log Analytics.
- Use `parse_json(tostring(Claims))` before reading `appid`.
- Caller identity and immutable image labels take precedence over tags.
- Never change a Container App without an approval-hook result and verified recovery target.