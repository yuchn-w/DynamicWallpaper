#!/bin/zsh
set -euo pipefail

TASK_DIR="${0:A:h}"
OUTPUT_DIR="$TASK_DIR/build"
APP_BUNDLE="$OUTPUT_DIR/動態壁紙.app"
APPLE_COMFORT_SOUND_SOURCE_DIR="/System/Library/PrivateFrameworks/HearingUtilities.framework/Versions/A/Resources"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

cd "$TASK_DIR"
mkdir -p /private/tmp/dynamic-wallpaper-clang-cache
mkdir -p /private/tmp/dynamic-wallpaper-swift-cache
mkdir -p /private/tmp/dynamic-wallpaper-swiftpm-cache

env \
    TMPDIR=/private/tmp \
    CLANG_MODULE_CACHE_PATH=/private/tmp/dynamic-wallpaper-clang-cache \
    SWIFT_MODULE_CACHE_PATH=/private/tmp/dynamic-wallpaper-swift-cache \
    SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/dynamic-wallpaper-swiftpm-cache \
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
if [[ -d "$APPLE_COMFORT_SOUND_SOURCE_DIR" ]]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/AppleComfortSounds"
    cp "$APPLE_COMFORT_SOUND_SOURCE_DIR"/*.m4a "$APP_BUNDLE/Contents/Resources/AppleComfortSounds/"
else
    echo "提醒：找不到這台 Mac 的系統背景聲音資源，App 仍可使用，但不會提供環境音。" >&2
fi
chmod +x "$APP_BUNDLE/Contents/MacOS/DynamicWallpaper"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "$APP_BUNDLE"
