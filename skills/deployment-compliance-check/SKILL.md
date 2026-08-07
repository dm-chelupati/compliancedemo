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
A compliant deployment requires both a CI-built image with the expected immutable labels and a noninteractive deployment identity. A deployment mechanism that updates the Container App must be separately provisioned and verified; do not infer that Event Grid or an Automation Runbook exists from the image-build workflow alone.
Non-compliant deployments should be flagged and reported. Revert only with explicit user approval and only when a known-good revision or compliant image exists.
This policy ensures every production change is traceable to a code commit, reviewed via PR, and auditable through the pipeline.

How the Pipeline Works
GitHub Actions builds the Docker image with immutable compliance labels and pushes it to ACR. A separately provisioned deployment mechanism must update the Container App through ARM. The Activity Log caller must be that mechanism's approved service principal or managed identity; GitHub Actions itself does not establish this proof.

Data Sources
Activity Logs in Log Analytics
Activity Logs flow to the Log Analytics workspace via diagnostic settings. Use QueryLogAnalyticsByWorkspaceId to run KQL against the AzureActivity table. Resolve the workspace from the subscription diagnostic setting named `activity-to-law`, then use its customer ID. If Log Analytics does not retain the target write, validate the exact Container App resource with `az monitor activity-log list`.

Container App Resource Tags
Use RunAzCliReadCommands to check tags on the Container App.

Docker Image Labels in ACR
The CI/CD pipeline bakes labels into every image at build time (deployed-by, commit-sha, pipeline-run-id, branch, repository, workflow). These are immutable once pushed and cannot be added or changed after the fact. An image pushed manually will not have these labels. A public image or an image absent from the configured ACR has no verifiable CI label set and must not be classified as compliant.

How to Detect Compliance
See compliance_detection.md for the detailed decision tree and well-known app IDs.

Step 1: Query Activity Logs
Query the AzureActivity table for Container App write operations. Extract claims.appid and Caller to identify who made the deployment. See compliance_detection.md for the KQL template.

Step 2: Classify each deployment by caller
Well-known Azure Portal / CLI / PowerShell app IDs, including Azure CLI `04b07795-a710-4e84-bea4-c697bab44963` and `04b07795-8ddb-461a-bbee-02f9e1bf7b46`, are NON-COMPLIANT.
Caller contains `@` or has a user identity claim -> NON-COMPLIANT.
Known pipeline managed identity -> proceed to Step 3.
Unknown service principal -> INVESTIGATE.
Caller identity ALWAYS takes precedence over tags.

Step 3: Verify Docker image labels (the tamper-proof check)
This is the most important step. Even if the caller is an approved managed identity, the image might have reached ACR outside the CI build. Do not assume an Event Grid or Automation path exists without verifying the deployed resources.

To catch this:

Get the currently running image tag from the Container App.
If the image is public or absent from the configured ACR, classify it as `NON-COMPLIANT BOOTSTRAP` unless separate evidence proves it is an approved immutable artifact.
Otherwise retrieve the image config from ACR and verify `deployed-by=pipeline`, a 40-character hexadecimal `commit-sha`, numeric `pipeline-run-id`, expected branch, repository, and workflow.
If any required label is missing or invalid -> NON-COMPLIANT regardless of caller.

Step 4: Verify resource tags (secondary)
Compliant pipelines stamp tags like deployed-by=pipeline, pipeline-run-id, commit-sha, repository. Missing deployed-by tag is additional non-compliance evidence, but tags alone are weak because a deployment mechanism can stamp them after a manual image push.

Step 5: Identify bootstrap-only drift
Classify as `NON-COMPLIANT BOOTSTRAP` when the running image is a placeholder or public image, tags use sentinel values such as `initial`, the configured ACR has no compliant application image, and there is no known-good revision. Report the failed bootstrap or deployment path; do not attempt a revision rollback because none exists.

Step 6: Generate compliance report
Report should include scan timestamp, time range, total/compliant/non-compliant counts, image label check results, and details of any violations.

Revert Procedures
IMPORTANT: Always get user approval before any revert action.

Option A - Reactivate a verified previous Container App revision only after confirming it is healthy and CI-compliant. Shift traffic before deactivating the non-compliant revision.

Option B - Re-run the CI/CD pipeline and the separately provisioned deployment mechanism to deploy a verified compliant image.

Do not revert a `NON-COMPLIANT BOOTSTRAP` finding when there is no prior revision or compliant image. Repair the CI/CD target or provision the missing deployment mechanism instead.

Notes
Activity Logs may take 5-15 minutes to appear in Log Analytics and can have a shorter retention window than the Activity Log API.
Parse `Claims` as `parse_json(tostring(Claims))` in KQL before reading `appid`.
Caller identity is authoritative; tags can be stale from previous deploys.
Docker image labels are the strongest signal because they are immutable once pushed to ACR.
Never revert without user approval.