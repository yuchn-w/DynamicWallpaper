#!/bin/zsh
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="${0:A:h:h}"
APP_NAME="DynamicWallpaper"
APP_BUNDLE="$ROOT_DIR/build/動態壁紙.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
"$ROOT_DIR/build_app.sh"

launch_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run)
        launch_app
        ;;
    --verify|verify)
        launch_app
        sleep 2
        pgrep -x "$APP_NAME" >/dev/null
        echo "動態壁紙已成功啟動"
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        launch_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        launch_app
        /usr/bin/log stream --info --style compact --predicate 'subsystem == "app.dynamicwallpaper.DynamicWallpaper"'
        ;;
    *)
        echo "用法：$0 [run|--verify|--debug|--logs|--telemetry]" >&2
        exit 2
        ;;
esac
