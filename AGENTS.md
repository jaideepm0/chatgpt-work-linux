# AGENTS.md

## Purpose

This repository builds `chatgpt-work-linux`, a community native Linux shell for
the public ChatGPT web service. It does not port, patch, or redistribute the
official macOS binary. Keep the application visibly labeled as unofficial.

## Architecture rules

- Rust/GTK/WebKitGTK is the primary runtime. Do not add Electron, Node, Python,
  a bundled browser, or a local HTTP server to the default runtime without an
  evidence-backed architecture decision.
- Remote content must never receive a native IPC or shell bridge. Keep URL,
  permission, file, and portal decisions in Rust and fail closed.
- Never disable WebKit/Chromium sandboxes, TLS verification, or web security.
- Use XDG portals for cross-desktop privileged operations, especially on
  Wayland. Portal features must remain user initiated.
- Keep one data/cache context per validated profile. Acquire GApplication's
  single-instance ownership before opening shared browser state.
- No polling updater or unbounded file log. Prefer package-manager updates and
  journald/stderr diagnostics.
- Shell scripts are build/install tooling only. Use `set -euo pipefail`, quote
  paths, publish outputs atomically, and preserve the active install on failure.
- The official DMG is ignored metadata-only reference input. Never execute,
  patch, bundle, or extract proprietary UI assets from it.

## Source map

- `src/gui.rs`: window, WebKit, permission, navigation, download, recovery, and
  native desktop behavior.
- `src/policy.rs`: trusted origin/scheme and filename decisions. Add tests for
  every policy change.
- `src/config.rs` / `src/paths.rs`: strict config and XDG/profile boundaries.
- `src/shortcut.rs` / `src/capture.rs`: portal workers only.
- `src/engine.rs`: Chromium and external-browser fallbacks.
- `scripts/fetch-upstream.sh` / `inspect-upstream.py`: bounded developer-only
  artifact provenance pipeline.
- `scripts/install-user.sh`: immutable user versions and atomic current/previous
  switch.
- `packaging/`: desktop/AppStream/Arch package sources.
- `docs/`: audit evidence, current snapshot, and architecture decisions.

## Validation

Run before handoff:

```bash
make check
make build
chatgpt-work-linux doctor --json
```

For runtime changes, also smoke-test Wayland and X11, single-instance/toggle,
offline loading, an external link, file upload/download, permission deny/allow,
screenshot cancellation/success, `--safe-mode`, and Chromium fallback. Inspect
the native package contents and ensure uninstall preserves profiles unless
`--purge` is explicit.

Performance-sensitive changes should be tested with two cores and a 768 MiB
memory limit. Do not use `target-cpu=native`; output must run on older x86_64
hardware.
