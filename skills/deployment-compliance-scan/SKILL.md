---
name: deployment-compliance-scan
description: |
  Performs read-only scheduled checks for Azure Container App CI/CD deployment compliance using Activity Log caller identity, active-image metadata, and resource tags.
tools:
  - QueryLogAnalyticsByWorkspaceId
  - GetAzCliHelp
  - RunAzCliReadCommands
---

Organization Policy
All Container App deployments MUST go through the approved GitHub Actions CI/CD pipeline. Deployments via Azure Portal, interactive Azure CLI, or PowerShell are non-compliant.

Scheduled Task Boundary
This skill is read-only and detection-only. Never modify a Container App, activate or deactivate revisions, alter traffic, dispatch a pipeline, or use a write-capable command. Report required remediation instead.

How to Detect Compliance
Use the decision tree in compliance_detection.md. Resolve AzureActivity through the subscription `activity-to-law` diagnostic setting, confirm the selected workspace contains recent rows, then inspect Container App write events. Parse claims with `parse_json(tostring(Claims))` before extracting `appid`.

For each active revision:
1. Classify its correlated deployment caller. If the relevant event is beyond Activity Log retention, report `unavailable: activity-log retention`; do not infer a caller from tags.
2. Verify the active image is a digest reference in the configured ACR and inspect its metadata labels (`deployed-by`, `commit-sha`, `pipeline-run-id`, `branch`, `repository`, `workflow`, and `pipeline-app-id`).
3. Treat resource tags only as secondary correlation metadata.
4. Classify the app as NON-COMPLIANT BOOTSTRAP when it uses the public placeholder image, has `initial` pipeline tags, has no application repository or compliant image in the configured ACR, and has no prior compliant revision.

Report Format
Report the scan timestamp in UTC, audit-window duration, scoped Container App count, and counts by classification. For each app include:
- Active revision, image, provisioning state, running state, and traffic weight
- Caller result, or `unavailable: activity-log retention`
- Configured ACR and image-label result
- Relevant deployment tags
- Verified compliant rollback target, if any
- Classification and required remediation

If no write events are returned, include workspace row-count sanity results. Do not represent an empty query as proof that no deployment ever occurred.

Required Remediation
For a standard non-compliant deployment, require an interactive investigation, a verified compliant target, and a successful compliance approval hook before any revert. For NON-COMPLIANT BOOTSTRAP, require repair and merge of the approved deployment path, then a successful pipeline deployment; do not manually replace the image or dispatch a pipeline from this scheduled scan.
