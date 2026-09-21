#!/usr/bin/env bash
# Builds Shepherd and zips it up for a GitHub release, e.g.:
#   scripts/package-release.sh
#   gh release create v0.1.0 Shepherd.zip --title v0.1.0 --notes "..."
set -euo pipefail

APP_NAME="Shepherd"
BUNDLE="${APP_NAME}.app"
ZIP="${APP_NAME}.zip"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/build-app.sh"

echo "→ Zipping ${BUNDLE}…"
rm -f "${ZIP}"
# ditto (not zip) preserves the code signature and resource forks correctly.
ditto -c -k --keepParent "${BUNDLE}" "${ZIP}"
rm -rf "${BUNDLE}"

echo "✓ ${ZIP} ready"
