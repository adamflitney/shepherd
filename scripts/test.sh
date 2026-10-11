#!/usr/bin/env bash
# Runs `swift test`. Swift Testing ships with Xcode; on a Command Line Tools-only machine SwiftPM
# can't find it or its interop library, so point it there explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ] && [ -d "$CLT/Frameworks/Testing.framework" ]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
        -Xlinker -F -Xlinker "$CLT/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "$@"
