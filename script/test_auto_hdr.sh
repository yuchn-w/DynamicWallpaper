#!/bin/zsh
set -euo pipefail
TASK_DIR="${0:A:h:h}"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
MODULE_CACHE_PATH="$TASK_DIR/work/auto-hdr-module-cache"
mkdir -p "$TASK_DIR/work/auto-hdr-tests"
mkdir -p "$MODULE_CACHE_PATH"
cd "$TASK_DIR"
swiftc -parse-as-library -sdk "$SDK_PATH" -module-cache-path "$MODULE_CACHE_PATH" \
    Sources/DynamicWallpaper/AutoHDRController.swift \
    Sources/DynamicWallpaper/DisplayHDRController.swift \
    Sources/DynamicWallpaper/YouTubeBrowserMonitor.swift \
    Sources/DynamicWallpaper/YouTubeHDRMetadataProvider.swift \
    Tests/AutoHDRTests/AutoHDRTests.swift \
    -o work/auto-hdr-tests/AutoHDRTests
work/auto-hdr-tests/AutoHDRTests
