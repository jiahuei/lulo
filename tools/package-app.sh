#!/bin/bash
set -euo pipefail

# Build both architectures independently of the runner's active architecture.
xcodebuild -project Lulo.xcodeproj -scheme Lulo -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build

app=build/Build/Products/Release/Lulo.app
archive=build/distribution/Lulo-macOS-universal.zip
mkdir -p build/distribution

# Ad-hoc signing needs no secrets and preserves App Sandbox for laptop testing.
codesign --force --sign - --entitlements App/Lulo.entitlements \
  --options runtime --timestamp=none "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"

# Check the delivered ZIP, including executable permissions and signed entitlements.
extracted=$(mktemp -d)
trap 'rm -rf "$extracted"' EXIT
ditto -x -k "$archive" "$extracted"
app="$extracted/Lulo.app"
test -x "$app/Contents/MacOS/Lulo"
lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/Lulo"
codesign --verify --deep --strict --verbose=2 "$app"
codesign --display --entitlements - --xml "$app" > "$extracted/entitlements.plist"
python3 - "$extracted/entitlements.plist" "$app/Contents/MacOS/Lulo" <<'PY'
import plistlib
import subprocess
import sys

with open("App/Lulo.entitlements", "rb") as expected, open(sys.argv[1], "rb") as actual:
    assert plistlib.load(actual) == plistlib.load(expected), "Packaged entitlements changed"

# A short launch detects immediate signing, loader, and sandbox startup failures.
app = subprocess.Popen([sys.argv[2]])
try:
    try:
        result = app.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    else:
        raise RuntimeError(f"Packaged app exited during launch: {result}")
finally:
    app.terminate()
    app.wait(timeout=10)
PY
shasum -a 256 "$archive"
