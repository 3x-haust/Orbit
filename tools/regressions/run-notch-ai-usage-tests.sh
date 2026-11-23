#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

output=$(mktemp -d "${TMPDIR:-/tmp}/orbit-ai-quota-tests.XXXXXX")
trap 'rm -rf "$output"' EXIT

xcrun swiftc -swift-version 5 -parse-as-library \
    Orbit/Modules/Notch/NotchAIUsage.swift tools/regressions/notch-ai-usage-tests.swift \
    -o "$output/notch-ai-usage-tests"
"$output/notch-ai-usage-tests"
