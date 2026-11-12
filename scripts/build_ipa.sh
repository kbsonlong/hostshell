#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$REPO_ROOT/apps/ios"
PROJECT="$IOS_DIR/HostShellIOS.xcodeproj"
TARGET_DIR="$REPO_ROOT/target"
ARCHIVE_PATH="${ARCHIVE_PATH:-$TARGET_DIR/HostShellIOS.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-$TARGET_DIR/ios-ipa}"
IPA_PATH="${IPA_PATH:-$EXPORT_DIR/HostShellIOS.ipa}"
EXPORT_METHOD="${EXPORT_METHOD:-debugging}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: IPA builds require macOS and Xcode." >&2
    exit 1
fi

for tool in cargo xcodebuild; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required tool not found: $tool" >&2
        exit 1
    fi
done

if [[ ! -d "$PROJECT" ]]; then
    echo "Error: Xcode project not found: $PROJECT" >&2
    exit 1
fi

mkdir -p "$TARGET_DIR" "$(dirname "$IPA_PATH")"

echo "==> Building Rust iOS framework..."
"$REPO_ROOT/scripts/build_ios.sh"

echo "==> Archiving HostShellIOS (build $BUILD_NUMBER)..."
xcodebuild \
    -project "$PROJECT" \
    -scheme HostShellIOS \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$TARGET_DIR/ios-derived-data" \
    -clonedSourcePackagesDirPath "$TARGET_DIR/ios-source-packages" \
    -packageCachePath "$TARGET_DIR/ios-package-cache" \
    -archivePath "$ARCHIVE_PATH" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Automatic \
    archive

EXPORT_OPTIONS="$TARGET_DIR/ios-export-options.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>$EXPORT_METHOD</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Exporting IPA ($EXPORT_METHOD)..."
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

EXPORTED_IPA="$(find "$EXPORT_DIR" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
if [[ -z "$EXPORTED_IPA" ]]; then
    echo "Error: export completed but no IPA was found in $EXPORT_DIR" >&2
    exit 1
fi

if [[ "$EXPORTED_IPA" != "$IPA_PATH" ]]; then
    mkdir -p "$(dirname "$IPA_PATH")"
    mv "$EXPORTED_IPA" "$IPA_PATH"
fi

echo "==> IPA build complete: $IPA_PATH"
