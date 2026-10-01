#!/usr/bin/env bash
# Builds ShepherdWeb (release) and installs it as a per-user LaunchAgent, so
# the mobile web view and its push notifications are always running.
#   scripts/install-web.sh              build, (re)install and start
#   scripts/install-web.sh uninstall    stop and remove
# The agent runs the binary in place from .build/release (its resource bundle
# sits next to it), so re-running this script after a code change is how you
# deploy it. Logs: ~/.shepherd/logs/shepherd-web.log
set -euo pipefail

LABEL="com.adamflitney.shepherd-web"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${HOME}/.shepherd/logs"

stop_agent() { launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true; }

if [ "${1:-}" = "uninstall" ]; then
    stop_agent
    rm -f "${PLIST}"
    echo "✓ Removed ${LABEL}"
    exit 0
fi

echo "→ Building ShepherdWeb (release)…"
(cd "${REPO}" && swift build -c release --product ShepherdWeb)

mkdir -p "${LOG_DIR}" "$(dirname "${PLIST}")"
cat > "${PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${REPO}/.build/release/ShepherdWeb</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/shepherd-web.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/shepherd-web.log</string>
</dict>
</plist>
PLIST

stop_agent
launchctl bootstrap "${DOMAIN}" "${PLIST}"
echo "✓ ${LABEL} installed and running (logs: ${LOG_DIR}/shepherd-web.log)"
