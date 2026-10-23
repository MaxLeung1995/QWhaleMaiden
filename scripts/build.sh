#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/cache
export CLANG_MODULE_CACHE_PATH="$PWD/build/cache"
export SWIFT_MODULECACHE_PATH="$PWD/build/cache"
APP="build/QWhaleMaiden.app"
STAGE="build/.QWhaleMaiden-stage.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Helpers"
COMMON=(-swift-version 5 -O -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/cache")
xcrun swiftc "${COMMON[@]}" Sources/Core.swift Sources/Agents.swift Sources/IPC.swift Sources/BridgeSetup.swift Sources/Services.swift Sources/Assets.swift Sources/PassThroughExit.swift Sources/Motion.swift Sources/RuntimeLog.swift Sources/App.swift -framework AppKit -framework WebKit -framework EventKit -framework ServiceManagement -framework ImageIO -framework Carbon -lsqlite3 -o "$STAGE/Contents/MacOS/QWhaleMaiden"
xcrun swiftc "${COMMON[@]}" Sources/Core.swift Sources/IPC.swift Sources/BridgeSetup.swift Sources/EventCLI.swift -lsqlite3 -o "$STAGE/Contents/Helpers/starbud-event"
cp Resources/settings-avatar.png "$STAGE/Contents/Resources/"
cp Info.plist "$STAGE/Contents/Info.plist"
cp Resources/*.html Resources/*.css Resources/*.js Resources/*.json "$STAGE/Contents/Resources/"
cp -R Resources/dsh "$STAGE/Contents/Resources/"
cp -R Resources/bridges "$STAGE/Contents/Resources/"
cp -R Resources/sounds "$STAGE/Contents/Resources/"
cp -R Resources/example-pack "$STAGE/Contents/Resources/"
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/settings-avatar.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size*2))
  sips -z "$double" "$double" Resources/settings-avatar.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
python3 scripts/build-icon.py "$ICONSET" "$STAGE/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$STAGE/Contents/Helpers/starbud-event"
codesign --force --sign - "$STAGE"
codesign --verify --strict "$STAGE"
rm -rf "$APP.previous"
if [ -d "$APP" ]; then mv "$APP" "$APP.previous"; fi
mv "$STAGE" "$APP"
echo "Built: $PWD/$APP"
