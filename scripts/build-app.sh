#!/usr/bin/env bash
# Builds Shepherd and assembles Shepherd.app in the current directory,
# ad-hoc signed. Shared by install.sh (installs it) and package-release.sh
# (zips it for a GitHub release) so the assembly steps only live in one place.
set -euo pipefail

APP_NAME="Shepherd"
BUNDLE="${APP_NAME}.app"

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
