---
name: deployment-compliance-check
description: |
  Checks whether Azure Container App deployments comply with the organization's CI/CD-only deployment policy. Uses Activity Log caller identity, immutable image labels, and resource tags.
  QueryLogAnalyticsByWorkspaceId
tools:
  - QueryLogAnalyticsByWorkspaceId
  - GetAzCliHelp
  - RunAzCliReadCommands
  - RunAzCliWriteCommands
---

Organization Policy
All Container App deployments MUST go through the approved GitHub Actions pipeline.

Deployments through Azure Portal, interactive Azure CLI, or PowerShell are non-compliant. A compliant deployment is made by the approved noninteractive service principal or managed identity and runs a pipeline-built image with the required immutable labels.

How the Pipeline Works
GitHub Actions builds the image, attaches immutable compliance labels, pushes it to ACR, authenticates to Azure with the approved noninteractive service principal, and deploys the resolved image digest directly to the Container App. The workflow verifies `/health` before stamping resource tags.

Data Sources
Activity Logs flow to Log Analytics through the subscription diagnostic setting. Resolve the authoritative workspace first:

az monitor diagnostic-settings subscription list --subscription <subscription-id> --query "value[?name=='activity-to-law'].workspaceId" -o tsv
az monitor log-analytics workspace show --ids <workspace-resource-id> --query customerId -o tsv

Use `AzureActivity` for caller evidence, Container App properties for images and tags, and ACR or the source registry to inspect image configuration labels.

How to Detect Compliance
See `compliance_detection.md` for the detailed decision tree and well-known app IDs.

Step 1: Query Activity Logs
Query `AzureActivity` for successful `Microsoft.App/containerApps/write` operations. Normalize claims with `parse_json(tostring(Claims))` before extracting `appid`. First verify that the workspace contains recent raw rows. If its resource-group query returns no writes, query the exact Container App resource through Azure Activity Log before treating the caller as unknown.

Step 2: Classify each deployment by caller
Known Portal, CLI, PowerShell, Visual Studio, or Azure Mobile App IDs are NON-COMPLIANT. A caller containing `@` is a user principal and is NON-COMPLIANT. An approved noninteractive identity proceeds to image verification; an unknown service principal remains INVESTIGATE unless image evidence proves non-compliance. Caller identity takes precedence over tags.

Step 3: Verify immutable image labels
Get the active revision image. For ACR-hosted images, inspect the ACR manifest config; for public or external images, inspect the source registry config. Required labels are `deployed-by=pipeline`, a 40-character `commit-sha`, numeric `pipeline-run-id`, `branch=main`, plus the expected `repository` and `workflow`. Missing or invalid labels make the deployment NON-COMPLIANT regardless of caller.

Step 4: Verify resource tags
Treat tags as secondary evidence only. The workflow writes `deployed-by`, `pipeline-run-id`, `commit-sha`, `branch`, `repository`, `workflow`, `image-digest`, and `deployer-app-id` after health validation. They are mutable and can remain from a prior deployment.

Step 5: Classify bootstrap-only state
Classify `NON-COMPLIANT BOOTSTRAP` when the active revision still runs the placeholder image, has bootstrap values such as `commit-sha=initial` and `pipeline-run-id=initial`, the expected ACR has no application image, and no prior compliant revision exists. This is not a rollback candidate: report remediation as blocked and require a compliant pipeline deployment.

Step 6: Generate compliance report
Report the scan timestamp, time range, total/compliant/non-compliant/bootstrap counts, caller evidence, image-label results, tags, revision health, and any blocked remediation.

Revert Procedures
Never modify a Container App without the approval hook permitting the action.

Option A: Reactivate a previous revision only when it is known-good and compliant; then shift traffic and deactivate the non-compliant revision.

Option B: Re-run the approved pipeline to deploy the last known compliant image. For bootstrap-only state, this is the only valid remediation once pipeline configuration and image publication are corrected.

Notes
Activity Logs can take 5-15 minutes to appear in Log Analytics.
Claims app IDs for Portal, CLI, PowerShell, Visual Studio, and Azure Mobile App are listed in `compliance_detection.md`.
Caller identity and image labels are authoritative; tags can be stale.
Docker image labels are immutable once pushed to a registry.
Never revert without user approval