#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
APP_NAME="TarteletHeadless"
BUNDLE_ID="com.mzkmnk.TarteletHeadless"
EXPECTED_TEAM_ID="${TARTELET_DEVELOPER_ID_TEAM_ID:-RRSM3L23N3}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURED_VERSION="$(awk -F ' = ' '/^MARKETING_VERSION = / { print $2 }' "$ROOT_DIR/xcconfigs/General.xcconfig")"
OUTPUT_DIR="${TARTELET_RELEASE_OUTPUT_DIR:-$ROOT_DIR/.build/release/$VERSION}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
    || "$VERSION" != "$CONFIGURED_VERSION" ]]; then
    echo "usage: $0 $CONFIGURED_VERSION" >&2
    exit 2
fi

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
    echo "The release checkout must be clean." >&2
    exit 1
fi

detect_developer_id_identity() {
    security find-identity -v -p codesigning \
        | awk -v team="($EXPECTED_TEAM_ID)" \
            '/Developer ID Application:/ && index($0, team) && identity == "" { identity = $2 } END { print identity }'
}

SIGNING_IDENTITY="${TARTELET_DEVELOPER_ID_IDENTITY:-$(detect_developer_id_identity)}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "No Developer ID Application identity was found for team $EXPECTED_TEAM_ID." >&2
    exit 1
fi

if ! git -C "$ROOT_DIR" tag --points-at HEAD | grep -Fxq "$VERSION"; then
    echo "HEAD must be tagged $VERSION before creating release assets." >&2
    exit 1
fi

asc notarization list --limit 1 >/dev/null

ASSET_NAME="$APP_NAME-$VERSION-macos-arm64.zip"
CHECKSUM_NAME="$ASSET_NAME.sha256"
NOTARY_LOG_NAME="$APP_NAME-$VERSION-notarization.json"
if [[ -e "$OUTPUT_DIR/$ASSET_NAME" || -e "$OUTPUT_DIR/$CHECKSUM_NAME" ]]; then
    echo "Release output already exists in $OUTPUT_DIR." >&2
    exit 1
fi

TEMP_ROOT="$(mktemp -d "/tmp/tartelet-headless-release.$VERSION.XXXXXX")"
ARCHIVE_PATH="$TEMP_ROOT/$APP_NAME.xcarchive"
DERIVED_DATA_PATH="$TEMP_ROOT/DerivedData"
PRE_NOTARY_ZIP="$TEMP_ROOT/$APP_NAME-pre-notary.zip"
APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
mkdir -p "$OUTPUT_DIR"

cd "$ROOT_DIR"
xcodegen generate
RESOLVED_DIRECTORY="$ROOT_DIR/Tartelet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$RESOLVED_DIRECTORY"
/bin/cp \
    "$ROOT_DIR/xcconfigs/TarteletHeadless.Package.resolved" \
    "$RESOLVED_DIRECTORY/Package.resolved"
xcodebuild archive \
    -project Tartelet.xcodeproj \
    -scheme Tartelet \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_ENTITLEMENTS= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ARCHS=arm64 \
    TARTELET_BUNDLE_ID="$BUNDLE_ID" \
    TARTELET_PRODUCT_NAME="$APP_NAME" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION=1

INFO_PLIST="$APP_PATH/Contents/Info.plist"
plutil -remove TarteletHeadlessBuild "$INFO_PLIST" 2>/dev/null || true
plutil -remove LSMultipleInstancesProhibited "$INFO_PLIST" 2>/dev/null || true
plutil -insert TarteletHeadlessBuild -bool true "$INFO_PLIST"
plutil -insert LSMultipleInstancesProhibited -bool true "$INFO_PLIST"

if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
    while IFS= read -r nested_code; do
        codesign \
            --force \
            --options runtime \
            --timestamp \
            --sign "$SIGNING_IDENTITY" \
            "$nested_code"
    done < <(find "$APP_PATH/Contents/Frameworks" -type f -print | sort)
fi
codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
grep -Fq "Authority=Developer ID Application:" <<< "$SIGNATURE_DETAILS"
grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<< "$SIGNATURE_DETAILS"
grep -Fq "Timestamp=" <<< "$SIGNATURE_DETAILS"
# `syspolicy_check notary-submission` can report only a non-actionable
# "Gatekeeper rejected this file" for a correctly signed app that has not yet
# received its first notarization ticket. The notary service is authoritative;
# the stricter distribution policy check still runs after stapling below.
test "$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")" = "$BUNDLE_ID"
test "$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")" = "$VERSION"
test "$(plutil -extract TarteletHeadlessBuild raw "$INFO_PLIST")" = true
test "$(plutil -extract LSMultipleInstancesProhibited raw "$INFO_PLIST")" = true

ditto -c -k --keepParent "$APP_PATH" "$PRE_NOTARY_ZIP"
asc notarization submit \
    --file "$PRE_NOTARY_ZIP" \
    --wait \
    --poll-interval 15s \
    --timeout 1h \
    --pretty > "$OUTPUT_DIR/$NOTARY_LOG_NAME"

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
syspolicy_check distribution --verbose "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

ditto -c -k --keepParent "$APP_PATH" "$OUTPUT_DIR/$ASSET_NAME"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$ASSET_NAME" > "$CHECKSUM_NAME"
)

echo "Created notarized release assets in $OUTPUT_DIR"
echo "Temporary archive retained at $TEMP_ROOT"
