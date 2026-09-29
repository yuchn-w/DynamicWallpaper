#!/bin/zsh
set -euo pipefail

TASK_DIR="${0:A:h}"
OUTPUT_DIR="$TASK_DIR/build"
APP_BUNDLE="$OUTPUT_DIR/動態壁紙.app"
YTDLP_SOURCE="$TASK_DIR/Resources/yt-dlp_macos"
GLASS_BRIDGE_SOURCE="$TASK_DIR/Sources/GlassBridge/DWGlassBridge.m"
GLASS_BRIDGE_OUTPUT="$OUTPUT_DIR/libDWGlassBridge.dylib"
# 允許在系統更新造成 Command Line Tools 編譯器與最新 SDK 暫時不同步時，
# 明確指定仍相容的 SDK；沒有指定時維持使用系統預設值。
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

cd "$TASK_DIR"
BUILD_CACHE_ROOT="${DYNAMIC_WALLPAPER_BUILD_CACHE:-$TASK_DIR/work/build-cache}"
TMP_ROOT="${TMPDIR:-$BUILD_CACHE_ROOT/tmp}"
CLANG_CACHE_PATH="$BUILD_CACHE_ROOT/clang"
SWIFT_CACHE_PATH="$BUILD_CACHE_ROOT/swift"
SWIFTPM_CACHE_PATH="$BUILD_CACHE_ROOT/swiftpm"
mkdir -p "$TMP_ROOT" "$CLANG_CACHE_PATH" "$SWIFT_CACHE_PATH" "$SWIFTPM_CACHE_PATH"

# NSGlassEffectView is a macOS 26 SDK API. Compile only this narrow bridge with
# the newest installed SDK while the Swift package remains on its compatible SDK.
GLASS_SDK_PATH=""
for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
    if [[ -d "$candidate" ]]; then
        GLASS_SDK_PATH="$candidate"
        break
    fi
done
if [[ -n "$GLASS_SDK_PATH" ]]; then
    clang -dynamiclib -fobjc-arc -mmacosx-version-min=14.0 \
        -isysroot "$GLASS_SDK_PATH" -framework AppKit \
        -install_name @rpath/libDWGlassBridge.dylib \
        "$GLASS_BRIDGE_SOURCE" -o "$GLASS_BRIDGE_OUTPUT"
fi

env \
    TMPDIR="$TMP_ROOT" \
    CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_PATH" \
    SWIFT_MODULE_CACHE_PATH="$SWIFT_CACHE_PATH" \
    SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE_PATH" \
    SDKROOT="$SDK_PATH" \
    swift build --disable-sandbox -c release --arch arm64

if [[ -d "$APP_BUNDLE" ]]; then
    rm -rf "$APP_BUNDLE"
fi
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp "$TASK_DIR/.build/release/DynamicWallpaper" "$APP_BUNDLE/Contents/MacOS/DynamicWallpaper"
cp "$TASK_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$TASK_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
chmod +x "$APP_BUNDLE/Contents/MacOS/DynamicWallpaper"
if [[ -x "$YTDLP_SOURCE" ]]; then
    cp "$YTDLP_SOURCE" "$APP_BUNDLE/Contents/Resources/yt-dlp_macos"
    chmod +x "$APP_BUNDLE/Contents/Resources/yt-dlp_macos"
fi
if [[ -f "$GLASS_BRIDGE_OUTPUT" ]]; then
    cp "$GLASS_BRIDGE_OUTPUT" "$APP_BUNDLE/Contents/Frameworks/libDWGlassBridge.dylib"
    chmod +x "$APP_BUNDLE/Contents/Frameworks/libDWGlassBridge.dylib"
fi
codesign --force --deep --sign - "$APP_BUNDLE"

echo "$APP_BUNDLE"
