# Unified Electron architecture decision

The earlier public-web Rust/WebKit client could display `chatgpt.com`, but it
could not provide the desktop Work product. The public `/work/` page is a
marketing route, which is why that implementation appeared as a dirty wrapper.

The current official `ChatGPT.dmg` is a unified Electron 42 application with a
portable ASAR, local app-server, plugins, native modules, and Chat/Work/Codex
surfaces. Rehosting that portable application plane with Linux Electron is the
selected compatibility architecture. The macOS executable and Apple-only
helpers are not run.

This decision is conditional on the hardening gates in `architecture.md`:
exact artifact and adapter provenance, deterministic patch acceptance,
packaged `app://` origin, enabled Chromium sandbox, Wayland-native windowing,
no localhost server, no runtime compilation/updater polling, bounded logs, and
atomic rollback-safe installation.

Generated builds remain unofficial local outputs and must not be
redistributed. See `work-upstream-assessment.md` for the artifact evidence and
`validation-report.md` for the verified Linux result.
