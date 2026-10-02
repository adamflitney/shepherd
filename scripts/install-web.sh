#!/usr/bin/env bash
# Runs the phone web view as its own always-on LaunchAgent, independent of the
# menu bar app. Most people don't want this: the Shepherd app hosts the same
# server itself (menu bar -> Mobile Access...), with a setup checklist. This is
# for running it headless or while developing the web view. Don't use both at
# once - they'd fight over the same port.
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

# bootout returns before launchd has finished tearing the service down, and
# an immediate bootstrap then fails with an I/O error - so wait it out.
stop_agent() {
    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    for _ in $(seq 1 50); do
        launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || return 0
        sleep 0.2
    done
}

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
