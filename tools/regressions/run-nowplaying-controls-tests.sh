#!/bin/bash
# Plays silence through two stand-in players and takes macOS's Now Playing for a few seconds.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <Debug products directory> <scratch directory>" >&2
    exit 2
fi
products=$(cd "$1" && pwd)
mkdir -p "$2"
output=$(cd "$2" && pwd)
library="$products/Orbit.app/Contents/MacOS/Orbit.debug.dylib"
if [[ ! -f "$library" ]]; then
    echo "Missing test library: $library" >&2
    exit 2
fi
swiftc -O tools/regressions/nowplaying-fake-player.swift -o "$output/fake-player"
for name in FakeMelon FakeVideo; do
    app="$output/$name.app"
    id="dev.orbit.test.$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    mkdir -p "$app/Contents/MacOS"
    cp "$output/fake-player" "$app/Contents/MacOS/$name"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
    codesign -s - --force "$app" 2>/dev/null
done
# MediaRemoteBridge looks for the adapter in the running executable's Frameworks folder.
mkdir -p "$output/Frameworks"
ln -sf "$products/Orbit.app/Contents/Frameworks/OrbitMediaRemote.dylib" "$output/Frameworks/OrbitMediaRemote.dylib"
swiftc -parse-as-library -I "$products" -F "$products" \
    -Xlinker -rpath -Xlinker "$products/Orbit.app/Contents/MacOS" \
    "$library" tools/regressions/nowplaying-controls-tests.swift -o "$output/nowplaying-controls-tests"
"$output/nowplaying-controls-tests" "$output" "$output/players.log"
