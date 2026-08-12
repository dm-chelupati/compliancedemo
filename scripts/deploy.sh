#!/usr/bin/env bash
# This repository permits Container App deployments only from the approved
# GitHub Actions workflow. Keeping a local az containerapp update helper would
# allow callers to bypass the required CI/CD identity and immutable image flow.
set -euo pipefail

cat >&2 <<'EOF'
scripts/deploy.sh is retired and intentionally performs no deployment.

Use the "Deploy Container App" GitHub Actions workflow on main. It builds the
SHA-tagged ACR image, stamps the required labels and tags, and updates the
configured Container App with the approved CI/CD identity.
EOF
exit 1
