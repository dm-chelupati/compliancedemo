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
Only the approved noninteractive service principal or managed identity may deploy a pipeline-built image.
Non-compliant deployments should be flagged, reported, and reverted only when a known-good target exists and the approval hook allows the change.
This policy ensures every production change is traceable to a code commit, reviewed via PR, and auditable through the pipeline.

How the Pipeline Works
GitHub Actions builds an image with immutable compliance labels, pushes it to ACR, and authenticates with the approved noninteractive service principal. The workflow deploys the pushed manifest digest directly to the Container App, verifies the revision and its `/health` endpoint, then stamps the resource tags. There is no Event Grid or Automation Runbook deployment hop.

Data Sources
Activity Logs in Log Analytics
Activity Logs flow to the Log Analytics workspace via diagnostic settings. Use QueryLogAnalyticsByWorkspaceId to run KQL against the AzureActivity table.

Resolve the authoritative workspace from the subscription diagnostic setting, then retrieve its customer ID:

az monitor diagnostic-settings subscription list --subscription <subscription-id> --query "value[?name=='activity-to-law'].workspaceId" -o tsv
az monitor log-analytics workspace show --ids <workspace-resource-id> --query customerId -o tsv

Container App Resource Tags
Use RunAzCliReadCommands to check tags on the Container App.

Docker Image Labels in ACR
The CI/CD pipeline bakes labels into every image at build time (deployed-by, commit-sha, pipeline-run-id, branch, repository, workflow). These are immutable once pushed — they cannot be added or changed after the fact. An image pushed manually (via Portal or docker push) will NOT have these labels.

How to Detect Compliance
See compliance_detection.md for the detailed decision tree and well-known app IDs.

Step 1: Query Activity Logs
Query AzureActivity for Container App write operations, using `parse_json(tostring(Claims))` to extract `appid`. First confirm the selected workspace has raw AzureActivity rows in the requested window. If its resource-group query has no Container App writes, query the exact resource with `az monitor activity-log list --resource-id <container-app-resource-id>` before concluding no write occurred; diagnostic settings can omit a resource write while other AzureActivity rows are present.

Step 2: Classify each deployment by caller
Well-known Azure Portal, CLI, PowerShell, Visual Studio, or Azure Mobile App IDs -> NON-COMPLIANT
Caller contains `@` (user principal) -> NON-COMPLIANT
Approved pipeline service principal or managed identity -> proceed to Step 3
Unknown service principal -> INVESTIGATE after Step 3
Caller identity always takes precedence over tags.

Step 3: Verify Docker image labels (the tamper-proof check)
Get the currently running image. Inspect the image config in ACR for ACR-hosted images, or the source registry for a public or external image. The config must contain `deployed-by=pipeline`, a 40-character `commit-sha`, numeric `pipeline-run-id`, `branch=main`, and the expected repository and workflow. Missing or invalid labels make the deployment NON-COMPLIANT regardless of caller.

Step 4: Verify resource tags (secondary)
The deployment helper stamps `deployed-by`, `pipeline-run-id`, `commit-sha`, `branch`, `repository`, `workflow`, and `deployer-app-id` only after revision and health checks pass. Tags are mutable and can remain from a prior deployment, so use them only as secondary evidence.

Step 5: Generate compliance report
Report scan timestamp, time range, total/compliant/non-compliant/bootstrap counts, caller evidence, image-label results, tags, and blocked remediation.

Revert Procedures
IMPORTANT: Always get user approval before any revert action.

Option A — Reactivate previous Container App revision: list revisions, activate the last known-good one, shift traffic, deactivate the non-compliant revision.

Option B — Re-run the CI/CD pipeline to redeploy the last known compliant image from the approved pipeline.

Notes
Activity Logs may take 5-15 minutes to appear in Log Analytics
claims.appid values for Portal/CLI/PowerShell are well-known Microsoft constants (see compliance_detection.md)
Caller identity is authoritative; tags can be stale from previous deploys
Docker image labels are the strongest signal — immutable once pushed to ACR
A direct user write or a manually sourced image is non-compliant even when stale tags appear pipeline-like
Never revert without user approval