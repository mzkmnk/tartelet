#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TarteletHeadless"
BUNDLE_ID="${TARTELET_BUNDLE_ID:-com.mzkmnk.TarteletHeadless}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
BUILD_LOG="$ROOT_DIR/.build/xcodebuild.log"
LAUNCH_AGENT_TARGET="gui/$(id -u)/$BUNDLE_ID"

detect_signing_identity() {
    security find-identity -v -p codesigning \
        | awk '/Apple Development:/ && identity == "" { identity = $2 } END { print identity }'
}

SIGNING_IDENTITY="${TARTELET_CODE_SIGN_IDENTITY:-$(detect_signing_identity)}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "No Apple Development signing identity was found." >&2
    echo "Set TARTELET_CODE_SIGN_IDENTITY to a local signing identity hash." >&2
    exit 1
fi

mkdir -p "$ROOT_DIR/.build"
cd "$ROOT_DIR"
xcodegen generate

if ! xcodebuild \
    -project Tartelet.xcodeproj \
    -scheme Tartelet \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    TARTELET_BUNDLE_ID="$BUNDLE_ID" \
    TARTELET_PRODUCT_NAME="$APP_NAME" \
    build >"$BUILD_LOG" 2>&1; then
    tail -n 80 "$BUILD_LOG" >&2
    exit 1
fi

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
plutil -remove TarteletHeadlessBuild "$INFO_PLIST" 2>/dev/null || true
plutil -remove LSMultipleInstancesProhibited "$INFO_PLIST" 2>/dev/null || true
plutil -insert TarteletHeadlessBuild -bool true "$INFO_PLIST"
plutil -insert LSMultipleInstancesProhibited -bool true "$INFO_PLIST"

codesign \
    --force \
    --deep \
    --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

launch_headless_app() {
    /usr/bin/open -g \
        --env TARTELET_HEADLESS=1 \
        --env TARTELET_USE_TART_EXEC=1 \
        --env TARTELET_RUN_OPTIONS=--no-graphics \
        --env "LLVM_PROFILE_FILE=$ROOT_DIR/.build/$APP_NAME-%p.profraw" \
        "$APP_BUNDLE"
}

launch_configuration_app() {
    /usr/bin/open \
        --env TARTELET_HEADLESS=0 \
        --env TARTELET_USE_TART_EXEC=1 \
        "$APP_BUNDLE"
}

if [[ "$MODE" != "--build-only" && "$MODE" != "build-only" ]]; then
    if launchctl print "$LAUNCH_AGENT_TARGET" >/dev/null 2>&1; then
        echo "$LAUNCH_AGENT_TARGET is loaded." >&2
        echo "Boot out the launch agent before launching a development build." >&2
        exit 1
    fi
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    for _ in {1..400}; do
        if ! pgrep -x "$APP_NAME" >/dev/null; then
            break
        fi
        sleep 0.1
    done
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "$APP_NAME did not terminate within 40 seconds." >&2
        exit 1
    fi
fi

case "$MODE" in
    run)
        launch_headless_app
        ;;
    --configure|configure)
        launch_configuration_app
        ;;
    --debug|debug)
        TARTELET_HEADLESS=1 TARTELET_USE_TART_EXEC=1 TARTELET_RUN_OPTIONS=--no-graphics \
            lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
        ;;
    --logs|logs)
        launch_headless_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        launch_headless_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        launch_headless_app
        sleep 2
        pgrep -x "$APP_NAME" >/dev/null
        ;;
    --build-only|build-only)
        ;;
    *)
        echo "usage: $0 [run|--configure|--build-only|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
