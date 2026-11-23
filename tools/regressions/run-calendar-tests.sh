#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <Debug products directory> <artifact directory>" >&2
    exit 2
fi
products=$(cd "$1" && pwd)
mkdir -p "$2"
output=$(cd "$2" && pwd)
# Import the Debug build, so tests exercise the app's real services and SwiftUI/AppKit views.
swiftc -parse-as-library -I "$products" -F "$products" \
    -Xlinker -rpath -Xlinker "$products/Orbit.app/Contents/MacOS" \
    "$products/Orbit.app/Contents/MacOS/Orbit.debug.dylib" \
    tools/regressions/calendar-tests.swift -o "$output/calendar-tests"
"$output/calendar-tests" "$output"
