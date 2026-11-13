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
app="$scratch/Orbit File Workflow Tests.app"
mkdir -p "$app/Contents/MacOS"
library="$products/Orbit.app/Contents/MacOS/Orbit.debug.dylib"
swiftc -parse-as-library -I "$products" -F "$products" \
    -module-cache-path "$scratch/module-cache" \
    -Xlinker -rpath -Xlinker "$products/Orbit.app/Contents/MacOS" \
    "$library" tools/regressions/file-tools-workflow-tests.swift -o "$app/Contents/MacOS/WorkflowTests"
python3 - "$app" "$scratch" <<'PY'
import plistlib, sys
from pathlib import Path
app, scratch = sys.argv[1:]
with (Path(app) / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier': 'com.lyu.orbit.file-workflow-tests',
                  'CFBundleName': 'Orbit File Workflow Tests',
                  'CFBundleExecutable': 'WorkflowTests',
                  'CFBundlePackageType': 'APPL',
                  'FileToolsScratch': scratch}, f)
PY
printf '%s\n' "$app"
