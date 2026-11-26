#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <Debug products directory> <scratch directory>" >&2
    exit 2
fi
products=$(cd "$1" && pwd)
mkdir -p "$2"
output=$(cd "$2" && pwd)
library=${ORBIT_TEST_LIBRARY:-"$products/Orbit.app/Contents/MacOS/Orbit.debug.dylib"}
if [[ ! -f "$library" ]]; then
    echo "Missing test library: $library (set ORBIT_TEST_LIBRARY to override)" >&2
    exit 2
fi
library_directory=$(cd "$(dirname "$library")" && pwd)
library="$library_directory/$(basename "$library")"
# Finder names follow the running program's languages; declaring Korean makes Home.app "홈", as on a Korean Mac.
cat > "$output/launcher-app-search-info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.3xhaust.Orbit.launcher-app-search-tests</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
</dict></plist>
PLIST
swiftc -parse-as-library -I "$products" -F "$products" \
    -Xlinker -rpath -Xlinker "$products/Orbit.app/Contents/MacOS" \
    -Xlinker -rpath -Xlinker "$library_directory" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$output/launcher-app-search-info.plist" \
    "$library" tools/regressions/launcher-app-search-tests.swift -o "$output/launcher-app-search-tests"
"$output/launcher-app-search-tests" -AppleLanguages "(ko-KR)"
