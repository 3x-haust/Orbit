#!/bin/bash
# Builds dist/Orbit-<version>.dmg from a signed Release Orbit.app.
#
#   tools/dmg/make-dmg.sh 1.0.1 [path/to/Orbit.app]
#
# Needs python3 (a venv with dmgbuild + Pillow is made in tools/dmg/.venv on first run).
# Sign with SIGN_IDENTITY (defaults to the identity that signed the app).
set -euo pipefail

VERSION="${1:?usage: make-dmg.sh <version> [Orbit.app]}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/tools/dmg"
APP="${2:-$ROOT/build-rel/Build/Products/Release/Orbit.app}"
OUT="$ROOT/dist/Orbit-$VERSION.dmg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -d "$APP" ] || { echo "No app at $APP — build Release first:"; echo "  xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release -derivedDataPath build-rel build"; exit 1; }
APPVER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$APPVER" = "$VERSION" ] || { echo "Orbit.app is $APPVER, not $VERSION"; exit 1; }
codesign --verify --deep --strict "$APP"

VENV="$HERE/.venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q dmgbuild pillow
fi

# Background: 1x + 2x in one TIFF so Retina screens get the sharp one.
"$VENV/bin/python" "$HERE/render_background.py" "$WORK" space
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null

# Volume icon: the app's own icon.
ICON="$APP/Contents/Resources/Orbit.icns"

mkdir -p "$ROOT/dist"
rm -f "$OUT"
"$VENV/bin/dmgbuild" -s "$HERE/dmg_settings.py" \
  -D app="$APP" -D background="$WORK/background.tiff" -D icon="$ICON" \
  "Orbit" "$OUT"

# Same identity the app is built with (project.yml's CODE_SIGN_IDENTITY, a certificate hash, so
# two certificates with the same name in the keychain can't make it ambiguous).
IDENTITY="${SIGN_IDENTITY:-$(sed -n 's/^ *CODE_SIGN_IDENTITY: *//p' "$ROOT/project.yml" | head -1 | tr -d '"')}"
if [ -n "$IDENTITY" ]; then
  codesign --sign "$IDENTITY" --timestamp=none "$OUT"
  codesign --verify "$OUT"
fi

echo "$OUT"
shasum -a 256 "$OUT"
