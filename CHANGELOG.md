# Changelog

## 0.1.0 - 2026-07-10

- Added the native Rust/GTK/WebKitGTK runtime with Chromium/browser fallbacks.
- Added strict navigation and permission mediation, isolated profiles, native
  downloads/notifications, companion mode, crash backoff, and safe mode.
- Added XDG portal global shortcuts and screenshot-to-clipboard integration.
- Added bounded official-artifact provenance tooling and a verified snapshot.
- Added atomic user-local installation, Arch packaging, desktop metadata,
  tests, architecture documentation, and security guidance.
- Added standard compositor decorations and native menus, settings,
  diagnostics, profile window state, strict cross-site storage prompts, and
  bounded media-capture controls.
- Added Google OAuth detection with a user-approved isolated Chromium handoff;
  cookies are never copied and browser security remains enabled.
- Fixed the handoff lifecycle so persistent profiles immediately release the
  WebKit engine instead of retaining two full renderers; private handoffs give
  an explicit Chromium-private relaunch path.
- Added cgroup-aware efficient-mode cache and WebKit memory-pressure policy,
  content-hashed release manifests, checksummed source packaging, and build
  path remapping.
- Fixed the diagnostics portal probe so its timeout is created inside the
  Tokio runtime; the installed `doctor --json` path now has a regression test.
- Keyed package build caches by the full source-archive hash to prevent stale
  outputs when deterministic archive timestamps are reused.
- Refreshed the official Work-era metadata reference to ChatGPT 1.2026.183.
- Added a canonical desktop/portal identity and least-privilege GNOME 50
  Flatpak manifest with checksummed locked Cargo sources, Wayland-first
  permissions, and a documented sandbox/authentication audit.
