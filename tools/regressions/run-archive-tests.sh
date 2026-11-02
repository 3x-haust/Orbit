#!/bin/bash
# Production engine, offline, without app signing.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ "$(uname -s)" != Darwin ]; then
    echo "Archive regressions require macOS (Darwin APIs and system libarchive)." >&2
    exit 2
fi
command -v swiftc >/dev/null
work=$(mktemp -d "${TMPDIR:-/tmp}/orbit-archive-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
swiftc Orbit/Modules/Archives/LibArchive.swift \
    Orbit/Modules/Archives/ArchiveEngine.swift \
    tools/regressions/archive-*.swift -o "$work/archive-tests"
"$work/archive-tests" "$@"
