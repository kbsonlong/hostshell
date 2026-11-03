#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIMULATOR_ID="${HOSTSHELL_IOS_SIMULATOR_ID:-7E8B0FFF-454B-4579-B4C3-DE976087FD5C}"
SKIP_IOS_BUILD="${HOSTSHELL_SKIP_IOS_BUILD:-0}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/hostshell-regression.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

step "Rust core/CLI tests"
cd "$ROOT"
cargo test --workspace --locked

step "CLI help and isolated import smoke test"
cargo build --release --locked -p hostshell-cli
mkdir -p "$SCRATCH/home" "$SCRATCH/xdg"
HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/xdg" ./target/release/hostshell-cli import crates/hostshell-core/tests/fixtures/joyy-like.config | tee "$SCRATCH/import.out"
grep -F 'Imported 4 host(s), 1 jump host(s), 1 warning(s):' "$SCRATCH/import.out" >/dev/null || fail "CLI import count/shape changed"
HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/xdg" ./target/release/hostshell-cli list | tee "$SCRATCH/hosts.out"
HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/xdg" ./target/release/hostshell-cli list-jumps | tee "$SCRATCH/jumps.out"
grep -F 'jump(' "$SCRATCH/hosts.out" >/dev/null || fail "ProxyJump host is not linked"
grep -F 'auth:agent' "$SCRATCH/hosts.out" >/dev/null || fail "agent fallback auth missing in imported hosts"
grep -F 'jump → engineer@jump.example.test:32200' "$SCRATCH/jumps.out" >/dev/null || fail "jump host asset missing"
# Re-import must replace by name, not duplicate entries.
HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/xdg" ./target/release/hostshell-cli import crates/hostshell-core/tests/fixtures/joyy-like.config >/dev/null
HOSTS="$(HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/xdg" ./target/release/hostshell-cli list | grep -c '^  \[')"
JUMPS="$(HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/xdg" ./target/release/hostshell-cli list-jumps | grep -c '^  \[')"
[ "$HOSTS" -eq 4 ] || fail "re-import duplicated hosts (count=$HOSTS)"
[ "$JUMPS" -eq 1 ] || fail "re-import duplicated jump hosts (count=$JUMPS)"

step "macOS Swift wire-model contract"
swiftc "$ROOT/apps/macos/Sources/HostShell/Core/Models.swift" "$ROOT/apps/macos/Tests/ModelContractCheck.swift" -o "$SCRATCH/macos-model-check"
"$SCRATCH/macos-model-check"
swiftc "$ROOT/apps/ios/Sources/HostShellIOS/Models.swift" "$ROOT/apps/ios/Tests/ModelContractCheck.swift" -o "$SCRATCH/ios-model-check"
"$SCRATCH/ios-model-check"

step "macOS app build"
"$ROOT/scripts/build_macos.sh"

if [ "$SKIP_IOS_BUILD" = "1" ]; then
  step "iOS app build skipped by HOSTSHELL_SKIP_IOS_BUILD=1"
else
  step "iOS Rust XCFramework build"
  "$ROOT/scripts/build_ios.sh"
  step "iOS simulator app build"
  xcodebuild -project "$ROOT/apps/ios/HostShellIOS.xcodeproj" \
    -scheme HostShellIOS \
    -skipPackagePluginValidation \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -derivedDataPath "$ROOT/apps/ios/.build/regression" \
    build CODE_SIGNING_ALLOWED=NO
fi

step "Final whitespace check"
git -C "$ROOT" diff --check
printf '\nPASS: HostShell regression baseline completed.\n'
