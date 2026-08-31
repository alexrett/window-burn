#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Window Burn"
PROCESS_NAME="WindowBurn"
BUNDLE_ID="dev.malikov.WindowBurn"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Support/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
RELEASE_DIR="$ROOT_DIR/dist/release"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
DMG_PATH="$RELEASE_DIR/WindowBurn.dmg"
SIGNING_PACKAGE="${WINDOW_BURN_SIGNING_PACKAGE:-}"
SKIP_NOTARIZATION=false

if [[ "${1:-}" == "--skip-notarization" ]]; then
    SKIP_NOTARIZATION=true
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--skip-notarization]" >&2
    exit 2
fi

EXPECTED_RELEASE_DIR="$ROOT_DIR/dist/release"
if [[ "$RELEASE_DIR" != "$EXPECTED_RELEASE_DIR" ]]; then
    echo "Refusing to replace unexpected release path: $RELEASE_DIR" >&2
    exit 1
fi

rm -rf -- "$RELEASE_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

swift build --package-path "$ROOT_DIR" -c release --arch arm64 --arch x86_64
BUILD_BINARY="$(
    swift build --package-path "$ROOT_DIR" -c release --arch arm64 --arch x86_64 \
        --show-bin-path
)/$PROCESS_NAME"

cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/$PROCESS_NAME"
cp "$ROOT_DIR/Sources/WindowBurn/Resources/torch-base.png" \
    "$APP_BUNDLE/Contents/Resources/torch-base.png"
cp "$ROOT_DIR/Support/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
chmod +x "$APP_BUNDLE/Contents/MacOS/$PROCESS_NAME"

SIGNING_IDENTITY="${WINDOW_BURN_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && -f "$SIGNING_PACKAGE/WB_MACOS_SIGN_IDENTITY.txt" ]]; then
    SIGNING_IDENTITY="$(tr -d '\r\n' < "$SIGNING_PACKAGE/WB_MACOS_SIGN_IDENTITY.txt")"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning \
            | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
            | head -n 1
    )"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "No Developer ID Application identity found." >&2
    exit 1
fi

/usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

if [[ "$SKIP_NOTARIZATION" == false ]]; then
    if [[ -z "$SIGNING_PACKAGE" ]]; then
        echo "WINDOW_BURN_SIGNING_PACKAGE must point to the local signing package." >&2
        exit 1
    fi
    for file in MACOS_NOTARY_KEY.txt WB_NOTARY_KEY_ID.txt WB_NOTARY_ISSUER_ID.txt; do
        if [[ ! -f "$SIGNING_PACKAGE/$file" ]]; then
            echo "Missing signing package file: $SIGNING_PACKAGE/$file" >&2
            exit 1
        fi
    done

    NOTARY_KEY="$TEMP_DIR/AuthKey.p8"
    NOTARY_ZIP="$TEMP_DIR/WindowBurn-notary.zip"
    base64 --decode < "$SIGNING_PACKAGE/MACOS_NOTARY_KEY.txt" > "$NOTARY_KEY"
    chmod 600 "$NOTARY_KEY"
    ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" \
        --key "$NOTARY_KEY" \
        --key-id "$(tr -d '\r\n' < "$SIGNING_PACKAGE/WB_NOTARY_KEY_ID.txt")" \
        --issuer "$(tr -d '\r\n' < "$SIGNING_PACKAGE/WB_NOTARY_ISSUER_ID.txt")" \
        --wait
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    spctl -a -vv -t execute "$APP_BUNDLE"
fi

DMG_SOURCE="$TEMP_DIR/dmg"
mkdir -p "$DMG_SOURCE"
cp -R "$APP_BUNDLE" "$DMG_SOURCE/$APP_NAME.app"
ln -s /Applications "$DMG_SOURCE/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_SOURCE" \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null

echo "Built Window Burn $VERSION"
file "$APP_BUNDLE/Contents/MacOS/$PROCESS_NAME"
shasum -a 256 "$DMG_PATH"
echo "$DMG_PATH"
