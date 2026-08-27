#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
CONFIGURATION="${CONFIGURATION:-release}"
ARTIFACT_DIRECTORY="$PROJECT_DIRECTORY/.build/artifacts"
APP_BUNDLE="$ARTIFACT_DIRECTORY/Explorer.app"
MODULE_CACHE_DIRECTORY="$PROJECT_DIRECTORY/.build/module-cache"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIRECTORY/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIRECTORY/swiftpm"
/bin/mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

cd "$PROJECT_DIRECTORY"
swift build --disable-sandbox -c "$CONFIGURATION"
BINARY_DIRECTORY="$(swift build --disable-sandbox -c "$CONFIGURATION" --show-bin-path)"

if [[ "$APP_BUNDLE" != "$PROJECT_DIRECTORY/.build/artifacts/Explorer.app" ]]; then
    echo "Refusing to package an unexpected application path: $APP_BUNDLE" >&2
    exit 1
fi

/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
/bin/cp "$BINARY_DIRECTORY/ExplorerApp" "$APP_BUNDLE/Contents/MacOS/ExplorerApp"
/bin/cp "$PROJECT_DIRECTORY/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/bin/cp "$PROJECT_DIRECTORY/Resources/Explorer.icns" "$APP_BUNDLE/Contents/Resources/Explorer.icns"

/usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist"
/usr/bin/codesign --force --sign - \
    --entitlements "$PROJECT_DIRECTORY/Resources/Explorer.entitlements" \
    "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

echo "$APP_BUNDLE"
