---
name: deployment-compliance-check
description: |
  Checks whether Azure Container App deployments comply with the CI/CD-only policy using Activity Log callers, ACR image labels, and resource tags.
  QueryLogAnalyticsByWorkspaceId
tools:
  - QueryLogAnalyticsByWorkspaceId
  - GetAzCliHelp
  - RunAzCliReadCommands
  - RunAzCliWriteCommands
---

Organization Policy
All Container App deployments MUST go through the approved GitHub Actions pipeline.

Deployments via Azure Portal, interactive Azure CLI, or PowerShell are non-compliant. Only the approved CI/CD service principal or managed identity may deploy a compliant image. Flag and report every violation. Remediate only when a known-good revision or approved image exists and the configured deployment approval hook permits the change.

How the Pipeline Works
GitHub Actions builds an image with compliance labels, pushes immutable SHA and convenience tags to ACR, signs in with the approved CI/CD service principal, and directly runs `az containerapp update` for the SHA-tagged image. Do not assume that Event Grid or an Automation Runbook deploys this application.

Data Sources
Activity Logs in Log Analytics
Activity Logs flow to Log Analytics through the subscription diagnostic setting. Resolve the `activity-to-law` setting first, then use its workspace ID to retrieve the customer ID. If the workspace contains activity rows but omits a Container App write, verify the exact resource with `az monitor activity-log list --resource-id <container-app-id>` before concluding that no write occurred.

Container App Resource Tags
Use `RunAzCliReadCommands` to inspect tags. Tags are secondary evidence and must never override caller identity or image evidence.

Docker Image Labels in ACR
The CI/CD workflow builds images with `deployed-by`, `commit-sha`, `pipeline-run-id`, `branch`, `repository`, and `workflow` labels. Labels are immutable after push, but they are evidence rather than cryptographic provenance; require both expected labels and an approved deployment caller. Do not treat a public bootstrap image as an ACR label lookup failure.

How to Detect Compliance
See compliance_detection.md for the decision tree, caller IDs, and KQL template.

Step 1: Discover the deployed state
List each Container App, its active revision, running image, tags, and revision history. Resolve the ACR configured for the app and enumerate repositories before attempting an ACR manifest query.

Step 2: Query and classify the deployment caller
Query successful `Microsoft.App/containerApps/write` operations and extract `claims.appid` and `Caller`. Portal, CLI, PowerShell, and user-principal callers are non-compliant. The expected CI/CD service principal or managed identity proceeds to image verification; an unknown service principal is investigate-only until image evidence is checked.

Step 3: Verify the active image
For an ACR image, retrieve its manifest/config and require all expected workflow labels. Missing or invalid labels make the deployment non-compliant regardless of tags. A valid label set with an unknown caller remains investigate-only.

Step 4: Handle bootstrap-only state
Classify an app as `NON-COMPLIANT BOOTSTRAP` when it is still on the public placeholder image, has `commit-sha=initial` and `pipeline-run-id=initial`, has no approved application image in ACR, and has no prior healthy revision. This is not a rollback candidate: report it and require a compliant forward deployment from GitHub Actions.

Step 5: Verify resource tags
Check for `deployed-by=pipeline` and related traceability tags. Missing tags are supporting evidence only; matching tags do not prove compliance.

Step 6: Generate the report
Include scan timestamp, time range, total/compliant/non-compliant/bootstrap counts, caller and image-label results, revisions examined, and any blocked remediation.

Revert Procedures
Before any revision activation, deactivation, traffic change, Container App update, or workflow re-run, invoke the configured deployment approval hook.

Option A: Reactivate the last known-good revision only when one exists, verify it is healthy, shift traffic, and deactivate the violating revision.

Option B: Re-run the approved GitHub Actions workflow to build and directly deploy the last known compliant SHA-tagged image.

Notes
- Activity Logs may take 5-15 minutes to appear in Log Analytics.
- Caller identity and image evidence outrank tags.
- Both documented Azure CLI application IDs are non-compliant; see compliance_detection.md.
- Never replace a bootstrap image with an unverified image or modify a Container App without the approval hook.