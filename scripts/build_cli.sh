#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "==> Building HostShell CLI..."
echo "==> Repo root: $REPO_ROOT"

cd "$REPO_ROOT"
cargo build --release -p hostshell-cli

BIN="$REPO_ROOT/target/release/hostshell-cli"
echo "==> Build finished successfully!"
"$BIN" --help 2>/dev/null || "$BIN" | head -3
echo "==> Binary: $BIN"
