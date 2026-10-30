#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "==> Building HostShell for macOS..."
echo "==> Repo root: $REPO_ROOT"

# 1. Build Rust core library (release)
echo "==> 1. Compiling Rust hostshell-core..."
cd "$REPO_ROOT"
cargo build --release -p hostshell-core

# 2. Build Swift macOS desktop app
echo "==> 2. Compiling Swift macOS client..."
cd "$REPO_ROOT/apps/macos"
swift build -c release -Xlinker -L"$REPO_ROOT/target/release" -Xlinker -lhostshell_core -Xlinker -rpath -Xlinker "@loader_path/../Frameworks"

# 3. Create HostShell.app bundle
echo "==> 3. Creating HostShell.app bundle..."
APP_DIR="$REPO_ROOT/target/HostShell.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$REPO_ROOT/apps/macos/.build/release/HostShell" "$APP_DIR/Contents/MacOS/HostShell"

# Copy dylib into Frameworks
cp "$REPO_ROOT/target/release/libhostshell_core.dylib" "$APP_DIR/Contents/Frameworks/libhostshell_core.dylib"

# Fix rpath in binary and dylib
install_name_tool -change "$REPO_ROOT/target/debug/deps/libhostshell_core.dylib" "@rpath/libhostshell_core.dylib" "$APP_DIR/Contents/MacOS/HostShell" 2>/dev/null || true
install_name_tool -change "$REPO_ROOT/target/release/libhostshell_core.dylib" "@rpath/libhostshell_core.dylib" "$APP_DIR/Contents/MacOS/HostShell" 2>/dev/null || true
install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_DIR/Contents/MacOS/HostShell" 2>/dev/null || true
install_name_tool -id "@rpath/libhostshell_core.dylib" "$APP_DIR/Contents/Frameworks/libhostshell_core.dylib" 2>/dev/null || true

# Write Info.plist
cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>HostShell</string>
    <key>CFBundleIdentifier</key>
    <string>com.hostshell.desktop</string>
    <key>CFBundleName</key>
    <string>HostShell</string>
    <key>CFBundleDisplayName</key>
    <string>HostShell</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Build finished successfully! App bundle generated at:"
echo "    $APP_DIR"
