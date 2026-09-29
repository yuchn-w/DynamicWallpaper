#!/bin/zsh
set -euo pipefail

TASK_DIR="${0:A:h}"
OUTPUT_DIR="$TASK_DIR/build"
APP_BUNDLE="$OUTPUT_DIR/動態壁紙.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

cd "$TASK_DIR"
CACHE_ROOT="$TASK_DIR/.build/module-cache"
mkdir -p "$CACHE_ROOT/tmp"
mkdir -p "$CACHE_ROOT/clang"
mkdir -p "$CACHE_ROOT/swift"
mkdir -p "$CACHE_ROOT/swiftpm"

env \
    TMPDIR="$CACHE_ROOT/tmp" \
    CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang" \
    SWIFT_MODULE_CACHE_PATH="$CACHE_ROOT/swift" \
    SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_ROOT/swiftpm" \
    SDKROOT="$SDK_PATH" \
    swift build --disable-sandbox -c release

if [[ -d "$APP_BUNDLE" ]]; then
    rm -rf "$APP_BUNDLE"
fi
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$TASK_DIR/.build/release/DynamicWallpaper" "$APP_BUNDLE/Contents/MacOS/DynamicWallpaper"
cp "$TASK_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$TASK_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
chmod +x "$APP_BUNDLE/Contents/MacOS/DynamicWallpaper"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "$APP_BUNDLE"
