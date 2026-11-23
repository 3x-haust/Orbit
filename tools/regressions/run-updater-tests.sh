#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $# -ne 2 && $# -ne 4 ]]; then
    echo "Usage: $0 <Debug products directory> <scratch directory> [legacy.app new.app]" >&2
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
swiftc -parse-as-library -I "$products" -F "$products" \
    -Xlinker -rpath -Xlinker "$products/Orbit.app/Contents/MacOS" \
    -Xlinker -rpath -Xlinker "$library_directory" \
    "$library" tools/regressions/updater-tests.swift -o "$output/updater-tests"
shift 2
"$output/updater-tests" "$@"
