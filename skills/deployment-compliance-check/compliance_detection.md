# Compliance Detection Decision Tree

## Overview

This document defines the complete decision tree for classifying Container App
deployments as compliant or non-compliant. The tree uses three signals in priority
order: **caller identity**, **Docker image labels**, and **resource tags**.

## Quick Reference — Compliance Verdicts

| # | Caller | Image Labels | Tags | Verdict |
|---|---|---|---|---|
| 1 | Automation MI | All 6 labels present | `deployed-by=pipeline` | ✅ COMPLIANT |
| 2 | Automation MI | Missing or incomplete | `deployed-by=pipeline` | ❌ NON-COMPLIANT (portal push via Event Grid) |
| 3 | Azure Portal / CLI / PS | Any | Any | ❌ NON-COMPLIANT |
| 4 | User principal (has @) | Any | Any | ❌ NON-COMPLIANT |
| 5 | Unknown SP | All 6 labels present | Pipeline tags | 🔍 INVESTIGATE |
| 6 | Unknown SP | Missing | Any | ❌ NON-COMPLIANT |

**Row 2 is the critical case** — this catches the "portal push" attack path where
someone pushes an image to ACR manually, triggering Event Grid → Automation → deploy.
The caller looks correct (Automation MI) and tags look correct, but the image was
NOT built by the CI/CD pipeline — proven by missing labels.

---

## Step 1: Query Deployment Events

### Primary: Az CLI (recommended)

```bash
az monitor activity-log list \
  --resource-group rg-compliancedemo \
  --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 \
  --offset {timeRange} \
  --query "[?operationName.value=='Microsoft.App/containerApps/write' && status.value=='Accepted'].{time:eventTimestamp, caller:caller, appid:claims.appid, ip:httpRequest.clientIpAddress, resource:resourceId}" \
  -o json
```

Access `claims.appid` directly — no JSON parsing needed.

### Fallback: KQL via Log Analytics

Use `QueryLogAnalyticsByWorkspaceId` with workspace ID `17c5506a-8871-4793-8470-c400a2114997`.
Do NOT use `QueryLogAnalyticsByResourceId` (known platform bug).
In KQL, use `parse_json(Claims)["appid"]` and filter on `ActivityStatusValue == "Success"`.

---

## Step 2: Classify Caller Identity

For each deployment event, classify the caller:

### Decision nodes (apply in order)

```
1. claims.appid == "c44b4083-3bb0-49c1-b47d-974e53cbdf3c"
   → Azure Portal → ❌ NON-COMPLIANT (stop here)

2. claims.appid == "04b07795-a710-4e84-bea4-c697bab44963"
   → Azure CLI (interactive) → ❌ NON-COMPLIANT (stop here)

3. claims.appid == "1950a258-227b-4e31-a9cf-717495945fc2"
   → Azure PowerShell → ❌ NON-COMPLIANT (stop here)

4. claims.appid == "872cd9fa-d31f-45e0-9eab-6e460a02d1f1"
   → Visual Studio → ❌ NON-COMPLIANT (stop here)

5. claims.appid == "0a7bdc5c-7b57-40be-9939-d4c5fc7cd417"
   → Azure Mobile App → ❌ NON-COMPLIANT (stop here)

6. caller contains "@"
   → User principal (manual change) → ❌ NON-COMPLIANT (stop here)

7. caller == "119bed36-0070-4466-9009-0773f412c204"
   → Automation Runbook MI (known pipeline deployer)
   → ⏳ PROCEED TO STEP 3 (verify image labels)

8. Any other service principal GUID
   → Unknown SP → ⏳ PROCEED TO STEP 3 (verify image labels)
```

### Well-known Azure Application IDs

| Application ID | Application Name |
|---|---|
| `c44b4083-3bb0-49c1-b47d-974e53cbdf3c` | Azure Portal |
| `04b07795-a710-4e84-bea4-c697bab44963` | Microsoft Azure CLI |
| `1950a258-227b-4e31-a9cf-717495945fc2` | Microsoft Azure PowerShell |
| `872cd9fa-d31f-45e0-9eab-6e460a02d1f1` | Visual Studio |
| `0a7bdc5c-7b57-40be-9939-d4c5fc7cd417` | Microsoft Azure Mobile App |

Any of these → the change was interactive/manual → **non-compliant**.

---

## Step 3: Verify Docker Image Labels (Critical)

This is the **most important step**. Even if the caller is the Automation MI,
the image may have been pushed to ACR manually (bypassing the CI/CD build).
Image labels prove the image was built by GitHub Actions.

### 3a. Get the currently running image tag

```bash
az containerapp show \
  --name ca-api-compliancedemo \
  --resource-group rg-compliancedemo \
  --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 \
  --query "properties.template.containers[0].image" -o tsv
```

Extract the tag: everything after the last `:` in the image reference.

### 3b. Retrieve image labels from ACR

**Method A: az acr manifest (if available)**

```bash
az acr manifest show-metadata \
  --registry acrcompliancedemoenqgb2 \
  --name "compliance-demo-api:<TAG>"
```

**Method B: ACR REST API (reliable fallback)**

```bash
# Step 1: Get token
TOKEN=$(az acr login --name acrcompliancedemoenqgb2 --expose-token --query accessToken -o tsv)

# Step 2: Get manifest to find config digest
MANIFEST=$(curl -s \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "https://acrcompliancedemoenqgb2.azurecr.io/v2/compliance-demo-api/manifests/<TAG>")

CONFIG_DIGEST=$(echo "$MANIFEST" | jq -r '.config.digest')

# Step 3: Get config blob → extract labels
LABELS=$(curl -s \
  -H "Authorization: Bearer $TOKEN" \
  "https://acrcompliancedemoenqgb2.azurecr.io/v2/compliance-demo-api/blobs/$CONFIG_DIGEST" | \
  jq '.config.Labels')

echo "$LABELS"
```

### 3c. Validate required labels

Check for ALL of these labels:

| Label | Validation Rule |
|---|---|
| `deployed-by` | Must equal `pipeline` |
| `commit-sha` | Must be a 40-character hex string (`[0-9a-f]{40}`) |
| `pipeline-run-id` | Must be a numeric string (GitHub Actions run ID) |
| `branch` | Must be present; warn if not `main` |
| `repository` | Must equal `dm-chelupati/compliancedemo` |
| `workflow` | Must equal `Deploy Container App` |

**Decision:**

```
All 6 labels present and valid
  → AND caller is Automation MI → ✅ COMPLIANT
  → AND caller is unknown SP   → 🔍 INVESTIGATE (who is this SP?)

Any label missing or invalid
  → ❌ NON-COMPLIANT regardless of caller
  → This image was NOT built by the CI/CD pipeline
```

---

## Step 4: Check Resource Tags (Secondary Confirmation)

```bash
az containerapp show \
  --name ca-api-compliancedemo \
  --resource-group rg-compliancedemo \
  --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 \
  --query tags -o json
```

Expected compliant tags:
- `deployed-by`: `pipeline`
- `deployment-method`: `eventgrid-automation`

> **Note**: Tags are the WEAKEST signal. The Automation Runbook stamps `deployed-by=pipeline`
> on every deployment it processes, including ones triggered by manual ACR pushes.
> Tags alone CANNOT distinguish compliant from non-compliant when the deploy goes
> through Event Grid. Always verify image labels first.

### Tag Inconsistency Matrix

| Caller | Image Labels | Tags | Verdict |
|---|---|---|---|
| Automation MI | All present | `deployed-by=pipeline` | ✅ Compliant |
| Automation MI | Missing | `deployed-by=pipeline` | ❌ Non-compliant (labels override tags) |
| Azure Portal | N/A | Stale from last deploy | ❌ Non-compliant |
| Azure Portal | N/A | `deployed-by=pipeline` | ❌ Non-compliant (caller overrides) |
| Unknown SP | All present | No pipeline tags | 🔍 Investigate |
| Unknown SP | Missing | Any | ❌ Non-compliant |

---

## Attack Path: Manual ACR Push via Portal

### The Bypass

1. User with ACR write access pushes an image via Azure Portal or `docker push`
2. ACR emits `ImagePushed` event to Event Grid
3. Event Grid triggers the Automation Runbook webhook
4. Runbook deploys the image using its Managed Identity
5. Activity Log shows `Caller: 119bed36-...` (Automation MI) — looks legitimate
6. Container App tags show `deployed-by=pipeline` — looks legitimate

### Why It Looks Compliant (But Isn't)

- **Caller**: Automation MI ✅ (same as real pipeline deploys)
- **Tags**: `deployed-by=pipeline` ✅ (stamped by runbook regardless)
- **Image labels**: ❌ MISSING — the manually pushed image was not built by GitHub Actions

### How Image Labels Catch It

The Docker image labels (`deployed-by`, `commit-sha`, `pipeline-run-id`, etc.) are
baked into the image at `docker build` time in GitHub Actions. An image pushed via
the Portal or CLI was built elsewhere — it will NOT have these labels.

**This is why Step 3 (image label verification) is non-negotiable for compliance.**

---

## Complete Decision Tree (Visual)

```
Deployment event detected
│
├─ Caller is well-known interactive app (Portal/CLI/PS/VS)?
│  └─ YES → ❌ NON-COMPLIANT
│
├─ Caller contains "@" (user principal)?
│  └─ YES → ❌ NON-COMPLIANT
│
├─ Caller is Automation MI (119bed36-...)?
│  │
│  ├─ Image labels ALL present and valid?
│  │  └─ YES → ✅ COMPLIANT
│  │
│  └─ Image labels missing or invalid?
│     └─ ❌ NON-COMPLIANT (manual ACR push via Event Grid)
│
└─ Caller is unknown service principal?
   │
   ├─ Image labels ALL present and valid?
   │  └─ 🔍 INVESTIGATE (identify the SP)
   │
   └─ Image labels missing?
      └─ ❌ NON-COMPLIANT
```

---

## Scheduled Task Report Format

When running as a scheduled compliance check, produce a report like:

```
## Deployment Compliance Report — {date}

**Container App**: ca-api-compliancedemo
**Current Image**: compliance-demo-api:{tag}
**Resource Group**: rg-compliancedemo

### Signal 1: Caller Identity
- Last deployer: {caller}
- Classification: {Automation MI / Portal / CLI / User / Unknown SP}
- Timestamp: {time}

### Signal 2: Docker Image Labels
- deployed-by: {value or MISSING}
- commit-sha: {value or MISSING}
- pipeline-run-id: {value or MISSING}
- branch: {value or MISSING}
- repository: {value or MISSING}
- workflow: {value or MISSING}
- Label check: {PASS / FAIL}

### Signal 3: Resource Tags
- deployed-by: {value or MISSING}
- deployment-method: {value or MISSING}

### Final Verdict: {COMPLIANT / NON-COMPLIANT / INVESTIGATE}
{If non-compliant: describe the issue and recommend remediation}
```
