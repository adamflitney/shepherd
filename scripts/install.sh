#!/usr/bin/env bash
# Builds Shepherd and installs it to /Applications.
set -euo pipefail

APP_NAME="Shepherd"
BUNDLE="${APP_NAME}.app"
DEST="/Applications/${BUNDLE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/build-app.sh"

echo "→ Installing to ${DEST}…"
if [ -w "/Applications" ]; then
    rm -rf "${DEST}"
    cp -R "${BUNDLE}" "${DEST}"
else
    sudo rm -rf "${DEST}"
    sudo cp -R "${BUNDLE}" "${DEST}"
fi

rm -rf "${BUNDLE}"

echo "✓ Shepherd installed to ${DEST}"
echo ""
echo "Note: To launch at login, open Shepherd, click the menubar icon, and toggle"
echo "\"Launch at Login\". Or add it manually in System Settings → General → Login Items."
