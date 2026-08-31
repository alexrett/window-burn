#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Window Burn"
PROCESS_NAME="WindowBurn"
BUNDLE_ID="dev.malikov.WindowBurn"
SIGNING_TEAM_ID="525W3628D2"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

swift build --package-path "$ROOT_DIR"
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/$PROCESS_NAME"

EXPECTED_BUNDLE="$ROOT_DIR/dist/Window Burn.app"
if [[ "$APP_BUNDLE" != "$EXPECTED_BUNDLE" ]]; then
    echo "Refusing to replace unexpected bundle path: $APP_BUNDLE" >&2
    exit 1
fi

/bin/rm -rf -- "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Sources/WindowBurn/Resources/torch-base.png" "$APP_RESOURCES/torch-base.png"
cp "$ROOT_DIR/Support/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
cp "$ROOT_DIR/Support/Info.plist" "$APP_CONTENTS/Info.plist"
chmod +x "$APP_BINARY"

SIGNING_IDENTITY="${WINDOW_BURN_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning \
            | sed -n "s/.*\"\\(Developer ID Application:[^\"]*(${SIGNING_TEAM_ID})\\)\".*/\\1/p" \
            | head -n 1
    )"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning \
            | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
            | head -n 1
    )"
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
/usr/bin/codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    "$APP_BUNDLE" >/dev/null

open_app() {
    /usr/bin/open -n -a "$APP_BUNDLE" "$@"
}

case "$MODE" in
    run)
        open_app
        ;;
    --demo|demo)
        open_app --args --demo
        ;;
    --demo-soak|demo-soak)
        open_app --args --demo-soak
        ;;
    --torch|torch)
        open_app --args --torch
        ;;
    --soak-and-burn|soak-and-burn)
        open_app --args --soak-and-burn
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app --args --demo
        sleep 2
        pgrep -x "$PROCESS_NAME" >/dev/null
        ;;
    *)
        echo "usage: $0 [run|--demo|--demo-soak|--torch|--soak-and-burn|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
