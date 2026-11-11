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
swiftc -parse-as-library -I "$products" -F "$products" \
    -Xlinker -rpath -Xlinker "$products/Orbit.app/Contents/MacOS" \
    "$products/Orbit.app/Contents/MacOS/Orbit.debug.dylib" \
    tools/regressions/capture-reference-tests.swift -o "$output/capture-reference-tests"
"$output/capture-reference-tests" "$output"
