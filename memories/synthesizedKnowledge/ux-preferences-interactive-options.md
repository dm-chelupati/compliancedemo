# UX Preference: Always Use Interactive Options UI

## Rule
When presenting the user with decision points, remediation choices, approval gates, or **any situation where there are discrete options to choose from**, ALWAYS use the `AskUserQuestion` tool with structured clickable options — NEVER present options as plain-text bullet points.

## When to Use
- Remediation options (e.g., revert image, skip, escalate)
- Approval gates before write operations
- Choosing between investigation paths
- Any scenario with 2–4 discrete choices

## How to Use Well
- **header**: Keep to ≤ 12 characters (e.g., "Remediate", "Action", "Confirm")
- **options**: 2–4 items, each with a short `label` (1–5 words) and a `description` explaining the impact
- Mark the recommended option first with `(Recommended)` prefix in the label
- Set `allowFreeText: true` so the user can still type a custom response
- Ask a specific, pointed question — not vague ones like "How should I proceed?"

## Example
```
AskUserQuestion(
  question: "The container app ca-api-compliancedemo is running a non-compliant image. How would you like to proceed?",
  header: "Remediate",
  options: [
    { label: "(Recommended) Revert to latest", description: "Update the container app to use the last known compliant image (compliance-demo-api:latest)" },
    { label: "Skip remediation", description: "Take no action now; the next scheduled scan will re-check compliance" },
    { label: "Investigate further", description: "Dig deeper into activity logs and image history before deciding" }
  ],
  allowFreeText: true
)
```

## Origin
User explicitly requested this on 2026-03-12 after the compliance remediation workflow presented options as bullet points instead of using the interactive UI. The skill documentation (SKILL.md lines 91-97, 113) already mandates this, but persistent memory reinforces it across all sessions and workflows.
