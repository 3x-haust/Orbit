#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <scratch directory>" >&2
    exit 2
fi
mkdir -p "$1"
output=$(cd "$1" && pwd)
swiftc -parse-as-library Orbit/Modules/OCR/OCR.swift \
    tools/regressions/ocr-tests.swift -o "$output/ocr-tests"
for mode in callback-and-throw callback-only throw-only success-then-throw real; do
    "$output/ocr-tests" "$mode"
done
