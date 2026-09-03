---
name: deployment-compliance-scan
description: Read-only scheduled scan for Container App deployment compliance.
tools:
  - QueryLogAnalyticsByWorkspaceId
  - GetAzCliHelp
  - RunAzCliReadCommands
---

Organization policy
All Container App deployments must use the approved GitHub Actions CI/CD pipeline. Portal, interactive Azure CLI, and PowerShell deployments are non-compliant.

This skill is for scheduled detection only. It must not modify Container Apps, revisions, workflows, tags, agent configuration, or any Azure resource.

Detection workflow
1. Query `AzureActivity` for successful `Microsoft.App/containerApps/write` operations and classify callers using `claims.appid` and `Caller`.
2. Read the current image, revision, registry, and resource tags for each Container App in scope.
3. Inspect the configured ACR repositories and image labels when an application image exists.
4. Classify the result using `compliance_detection.md`. Use `NON-COMPLIANT BOOTSTRAP` when the app has the public placeholder image, `initial` tags, no application image in ACR, and no later successful write in the available activity window.
5. Report the scan timestamp, time range, total/compliant/non-compliant counts, caller evidence, image-label evidence, tag evidence, and whether a safe rollback target exists.

For a non-compliant deployment, report the required approved CI/CD remediation. Do not perform or dispatch remediation from this skill.
