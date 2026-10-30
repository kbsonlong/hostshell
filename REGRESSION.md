# HostShell regression baseline

This is the required regression gate before merging or shipping changes to shared SSH behavior, config import, authentication, persistence, or a client UI.

## Run the full local baseline

```sh
./scripts/check_regression.sh
```

It runs, in order:

1. `cargo fmt --all -- --check`
2. `cargo test --workspace --locked`
3. CLI release build and isolated `import → list/list-jumps → re-import` smoke test using `crates/hostshell-core/tests/fixtures/joyy-like.config`
4. macOS and iOS Swift model contract checks for the Rust wire values `auth: "agent"`, `proxy_mode: "proxy_command"`, and `jump_hosts`
5. macOS release app bundle build
6. iOS device + simulator Rust XCFramework build
7. iOS Simulator Xcode app build for the configured simulator ID
8. `git diff --check`

The CLI smoke test uses a temporary HOME/XDG config directory. It does not read or modify the user's SSH configuration and does not connect to any server.

## Simulator selection

By default, the iOS build targets the HostShell iPhone 17 simulator created for this checkout (`7E8B0FFF-454B-4579-B4C3-DE976087FD5C`). Override it on another machine:

```sh
HOSTSHELL_IOS_SIMULATOR_ID="<simulator-udid>" ./scripts/check_regression.sh
```

If only Rust/macOS and wire-model checks are needed (for example, when the iOS SDK/runtime is unavailable or disk space is constrained):

```sh
HOSTSHELL_SKIP_IOS_BUILD=1 ./scripts/check_regression.sh
```

This is a partial gate and must not be reported as the full three-client baseline passing.

## Coverage map

| Surface | Automated guard |
|---|---|
| Rust formatting | Current workspace contains pre-existing rustfmt drift; run `cargo fmt --all -- --check` as a separate cleanup gate after formatting debt is resolved. The regression script does not reformat unrelated files. |
| SSH config parsing: direct, ProxyCommand, wildcard skip | `test_parse_ssh_config_subset` |
| ProxyJump reference → JumpHost UUID, missing reference warning | `test_import_resolves_proxyjump_and_skips_wildcard_host`, `test_import_proxyjump_missing_target_is_warning_and_not_dangling` |
| Agent/ProxyCommand serialized values | `test_cli_wire_auth_and_proxy_command_values` + macOS/iOS Swift model checks |
| Host/jump storage and re-import dedupe | `test_config_store_crud` + CLI re-import smoke test |
| known_hosts persistence semantics, stage event JSON | `unit_tests.rs` |
| Rust ↔ Swift import response (`hosts`, `jump_hosts`, `warnings`) | both Swift model checks |
| CLI surface compiles | workspace tests + release build |
| macOS desktop app compiles and bundle links core dylib | `scripts/build_macos.sh` |
| iOS Rust device/simulator libraries and SwiftUI app compile | `scripts/build_ios.sh` + Xcode simulator build |

## Manual release checks

Offline automation cannot prove that real credentials, a live SSH agent, a bastion, Cloudflare Access, or remote terminal behavior works in every environment. Before release, manually verify one direct host, one ProxyJump target, one ProxyCommand/Cloudflare host (if used), agent authentication in a Finder-launched macOS app, terminal keyboard/output, and window/terminal resize. Never put real credentials into fixtures or CI logs.

The suite intentionally does not perform networked logins. Use a dedicated, explicitly approved staging account for that check rather than coupling a normal regression run to production infrastructure.
