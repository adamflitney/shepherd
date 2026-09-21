#!/usr/bin/env bash
# Builds Shepherd and installs it to /Applications.
set -euo pipefail

APP_NAME="Shepherd"
BUNDLE="${APP_NAME}.app"
DEST="/Applications/${BUNDLE}"

echo "→ Building release binary…"
swift build -c release

echo "→ Assembling ${BUNDLE}…"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp ".build/release/${APP_NAME}" "${BUNDLE}/Contents/MacOS/"
cp "Resources/Info.plist"       "${BUNDLE}/Contents/"
[ -f "Resources/AppIcon.icns" ] && cp "Resources/AppIcon.icns" "${BUNDLE}/Contents/Resources/"

# SPM resource bundle (bundled hook scripts, read via Bundle.module at
# runtime). SPM's generated accessor looks for this bundle at the .app's
# own top level (next to Bundle.main.bundleURL), but codesign rejects any
# unsealed content there - a valid .app must keep everything under
# Contents/. So this goes in the standard Contents/Resources/ location
# instead, and HookInstaller falls back to checking there directly when
# Bundle.module's own lookup comes up empty.
if [ -d ".build/release/${APP_NAME}_${APP_NAME}.bundle" ]; then
    cp -R ".build/release/${APP_NAME}_${APP_NAME}.bundle" "${BUNDLE}/Contents/Resources/"
fi

echo "→ Ad-hoc code signing…"
codesign --force --deep --sign - "${BUNDLE}"

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
