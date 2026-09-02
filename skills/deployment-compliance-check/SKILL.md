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
Non-compliant deployments should be flagged, reported, and reverted only with explicit user approval.
This policy ensures every production change is traceable to a code commit, reviewed via PR, and auditable through the pipeline.

Expected Deployment Evidence
A compliant image is built by GitHub Actions, carries immutable compliance labels, and is pushed to the configured ACR. The Container App update must be performed by an approved Azure identity. Do not assume a particular Event Grid, Automation, or direct-update implementation exists: verify the current deployment topology before relying on caller identity as pipeline evidence.

Data Sources
Activity Logs in Log Analytics
Activity Logs flow to the Log Analytics workspace via diagnostic settings. Use QueryLogAnalyticsByWorkspaceId to run KQL against the AzureActivity table.

To discover the workspace ID, resolve the subscription diagnostic setting first, then retrieve its customer ID:

az monitor diagnostic-settings subscription list --subscription <subscription-id> --query "value[?name=='activity-to-law'].workspaceId" -o tsv
az monitor log-analytics workspace show --ids <workspace-resource-id> --query customerId -o tsv

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
This is the strongest deployment-origin signal. Get the current image reference, then retrieve its ACR manifest/config and verify the expected labels: deployed-by=pipeline, a 40-character commit-sha, numeric pipeline-run-id, branch, repository, and workflow.

If the image is public or absent from the configured ACR, labels cannot be verified. Classify it as NON-COMPLIANT BOOTSTRAP when it is the bootstrap placeholder and the app also has initial tags, no compliant ACR image, and no prior known-good revision. Do not invent an image label result for a public image.

If labels are missing or invalid on an ACR image, classify NON-COMPLIANT regardless of caller. This also catches a manual ACR push that later triggers an otherwise legitimate deployment path.

Step 4: Verify resource tags (secondary)
Compliant deployments stamp tags such as deployed-by=pipeline, pipeline-run-id, commit-sha, and repository. Tags are weak evidence: they can be stale or copied from an earlier deployment, so caller identity and immutable image labels always take precedence.

Step 5: Generate compliance report
Report should include scan timestamp, time range, total/compliant/non-compliant counts, image label check results, and details of any violations.

Use this format for scheduled scans:

```text
Deployment compliance scan
- Scan timestamp (UTC): <timestamp>
- Evidence window: <time range>
- Scope: <resource group / Container Apps>
- Summary: total=<n>, compliant=<n>, non-compliant=<n>, investigate=<n>

Per app
- App / active revision: <name> / <revision>
- Classification: COMPLIANT | NON-COMPLIANT | NON-COMPLIANT BOOTSTRAP | INVESTIGATE
- Caller identity: <caller and app ID, or unavailable because of retention>
- Image and label check: <image reference and label result>
- Tags: <relevant tag result>
- Violation or missing prerequisite: <detail>
- Remediation candidate: <known-good revision or compliant image, if any>

Action: Scheduled scans are detection-only; no resource changes were made.
```

Revert Procedures
IMPORTANT: Always get user approval before any revert action.

Option A — Reactivate previous Container App revision: list revisions, activate the last known-good one, shift traffic, deactivate the non-compliant revision.

Option B — Re-run the CI/CD pipeline to redeploy the last known compliant image from the approved pipeline.

Notes
Activity Logs may take 5-15 minutes to appear in Log Analytics. Normalize Claims with parse_json(tostring(Claims)) before reading appid.
The direct Activity Log fallback has a rolling retention boundary; an older bootstrap write can be unavailable even when the active revision still exists. Report caller identity as unavailable because of retention rather than treating missing rows as compliant evidence.
Caller identity is authoritative when the relevant write is available; otherwise use the current image, labels, tags, and revision inventory to classify bootstrap-only state.
Docker image labels are the strongest signal because they are immutable once pushed to ACR.
Scheduled scans are detection-only even if an older task prompt requests remediation. Do not update, reactivate, deactivate, or shift traffic during a scheduled scan.
Never revert without explicit user approval and a verified compliant image or known-good revision.