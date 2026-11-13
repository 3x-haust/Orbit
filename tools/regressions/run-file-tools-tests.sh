#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <Debug products directory> <scratch directory>" >&2
    exit 2
fi
products=$(cd "$1" && pwd)
mkdir -p "$2"
scratch=$(cd "$2" && pwd)
output="$scratch/$(uuidgen)"
mkdir -p "$output"
library=${ORBIT_TEST_LIBRARY:-"$products/Orbit.app/Contents/MacOS/Orbit.debug.dylib"}
if [[ ! -f "$library" ]]; then
    echo "Missing test library: $library (set ORBIT_TEST_LIBRARY to override)" >&2
    exit 2
fi
library_directory=$(cd "$(dirname "$library")" && pwd)
library="$library_directory/$(basename "$library")"
swiftc -parse-as-library -I "$products" -F "$products" \
    -module-cache-path "$output/module-cache" \
    -Xlinker -rpath -Xlinker "$products/Orbit.app/Contents/MacOS" \
    -Xlinker -rpath -Xlinker "$library_directory" \
    "$library" tools/regressions/file-tools-tests.swift -o "$output/file-tools-tests"
"$output/file-tools-tests" "$output"
