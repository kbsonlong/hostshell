#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Homebrew's rustc may not contain rustup-installed Apple std targets. Prefer
# the rustup stable toolchain when available so device/simulator builds use
# the same sysroot that `rustup target add` manages.
if command -v rustup >/dev/null 2>&1; then
    RUSTUP_CARGO="$(rustup which cargo --toolchain stable 2>/dev/null || true)"
    if [ -n "$RUSTUP_CARGO" ]; then
        export PATH="$(dirname "$RUSTUP_CARGO"):$PATH"
    fi
fi

echo "==> Building hostshell-core for iOS targets..."

# Supported iOS targets
TARGET_DEVICE="aarch64-apple-ios"
TARGET_SIMULATOR="aarch64-apple-ios-sim"

echo "==> Adding Rust iOS targets..."
rustup target add "$TARGET_DEVICE" "$TARGET_SIMULATOR" 2>/dev/null || true

echo "==> Compiling for iOS Device ($TARGET_DEVICE)..."
cargo build --release --target "$TARGET_DEVICE" -p hostshell-core

echo "==> Compiling for iOS Simulator ($TARGET_SIMULATOR)..."
cargo build --release --target "$TARGET_SIMULATOR" -p hostshell-core

OUTPUT_DIR="$REPO_ROOT/apps/ios/Frameworks"
mkdir -p "$OUTPUT_DIR"

echo "==> Creating iOS XCFramework..."
rm -rf "$OUTPUT_DIR/HostShellCore.xcframework"

xcodebuild -create-xcframework \
    -library "$REPO_ROOT/target/$TARGET_DEVICE/release/libhostshell_core.a" \
    -headers "$REPO_ROOT/crates/hostshell-core/include" \
    -library "$REPO_ROOT/target/$TARGET_SIMULATOR/release/libhostshell_core.a" \
    -headers "$REPO_ROOT/crates/hostshell-core/include" \
    -output "$OUTPUT_DIR/HostShellCore.xcframework"

echo "==> iOS build script completed."
