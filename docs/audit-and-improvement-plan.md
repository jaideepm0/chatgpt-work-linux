# Audit and improvement plan

Date: 2026-07-13

## Current baseline

The production baseline is the Rust/GTK/WebKitGTK client. The separate
`codex-desktop-linux` checkout was reviewed for provenance, lifecycle, portal,
packaging, and failure-handling lessons, but its source is not vendored and its
Electron/ASAR runtime is not part of this product.

The official unified ChatGPT reference is `26.707.62119`, build `5211`,
SHA-256
`c243c94f8de6a51f5530ffe1f8d0c1588733d890ac692e34aaca06d95ba637ca`.
It is a 615,738,501-byte ARM64 macOS Electron app. The schema-3 snapshot
inventories eight bundled plugin families, 11 embedded app/XPC components, and
six privacy usage categories without executing the artifact.

## Completed in this audit

- Removed `compat/codex-desktop-linux` from every reachable Git snapshot and
  pruned the copied objects; the external checkout remains the reference.
- Removed build/test coupling to the copied tree and restored Rust/GTK as the
  default build, run, doctor, install, and validation path.
- Corrected the official endpoint from the 78 MB ChatGPT Classic download to
  the 615 MB unified Chat/Work/Codex desktop artifact linked by the current
  ChatGPT download page.
- Added an exhaustive structural resource-bundle inventory, privacy-category
  keys, and embedded-component names to the bounded inspector.
- Added an atomic refresh/check script with network and offline modes.
- Separated standalone-product evidence from optional features implemented by
  the reference Linux project.

## P0 — release gates

1. Run `make check`, `make build`, and
   `target/release/chatgpt-work-linux doctor --json` for every handoff.
2. Complete deliberate KDE Wayland and X11 QA for single-instance/toggle,
   offline recovery, external link, upload/download, permission deny/allow,
   screenshot cancel/success, safe mode, and Chromium fallback.
3. Inspect Arch and Flatpak contents. Confirm no DMG, Mach-O executable,
   Electron, Node, Python server, sandbox-disable flag, or copied reference tree
   ships; uninstall must preserve profiles unless purge is explicit.
4. Add GUI-level permission tests around trusted sender, display-vs-camera
   media requests, capture indicator, and Settings persistence.

## P1 — native parity and robustness

1. Add capability diagnostics that distinguish service-delivered Work surfaces
   from local host capabilities and explain portal/backend failures.
2. Add a settings “restore safe defaults” transaction only after tests prove it
   leaves profiles, cookies, and service data intact.
3. Expand screenshot QA across KDE/GNOME portal backends, multi-monitor scale,
   denial, cancellation, and clipboard ownership loss.
4. Benchmark cold/warm start, PSS/RSS, idle CPU, and crash recovery under two
   cores and 768 MiB; retain generic x86_64 output.
5. Add CI `refresh-upstream-snapshot.sh --check` in a controlled network lane,
   while keeping ordinary builds fully offline and reproducible.

## P2 — local context research

1. Prototype observation-only app context outside the default runtime. Require
   explicit target selection, a redacted preview, strict size/time limits,
   approval for each transfer, cancellation, and an audit record.
2. Keep the prototype inaccessible to remote WebKit content. Use a typed,
   versioned, session-scoped protocol only with a trusted local agent surface.
3. Threat-model AT-SPI metadata, terminal titles, clipboard content,
   multi-monitor screenshots, focus spoofing, and portal grant persistence.
4. Consider input automation only after observation-only acceptance. Require
   verified target focus, action preview, per-action approval, emergency stop,
   revocation, and no unrestricted `uinput`, `ydotool`, or shell bridge.

## Non-goals

- No Electron/ASAR rehosting, macOS binary translation, proprietary UI copy,
  private-service emulation, or publication of the DMG.
- No remote-page native IPC/shell bridge, sandbox/TLS/web-security bypass,
  polling updater, or unbounded file log.
- No imitation of Handoff, Apple Events, macOS Accessibility, or Apple-native
  Calendar/Contacts/Reminders integrations.

Detailed evidence is in `upstream-feature-audit.md`,
`work-upstream-assessment.md`, `codex-desktop-linux-review.md`, and
`upstream-snapshot.json`.
