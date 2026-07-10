# Audit and improvement plan

Date: 2026-07-10

This is the active roadmap for the unified Electron Work build. The former
Rust/WebKit roadmap is complete and preserved in Git history and at
`rust-webkit-baseline-v0.1.0`; the lightweight client continues separately as
`chatgpt-desktop-linux`.

## Reviewed baseline

The upstream input is ChatGPT `26.707.31428` / Electron `42.1.0`, exact SHA-256
`6f67af7e2f934093ab8afebcec11374d40c8db8f9100fb6620f24155401d8319`.
It is byte-identical to the contemporary artifact reviewed by the sibling
`codex-desktop-linux` project. The mature compatibility engine was imported at
reference commit `f3836c9c225cb0a2868f05bf0bc031f20c57c56f`, with its MIT
license, provenance, deterministic patch registry, and tests.

The first exact-artifact audit found five required breaks: primary window
options, native titlebar, avatar-overlay input, tray fallback, and the
main-process aggregate. Each now has an exact `26.707` semantic fixture. The
full patch suite passes 333 tests and the current artifact has zero required
failures. Optional drift remains reported rather than guessed.

## Remediated production risks

| Priority | Reference behavior | Implemented response |
|---|---|---|
| P0 | Launcher always added `--no-sandbox` and `--disable-gpu-sandbox`. | Both switches were removed and the build rejects their return. Renderer command lines contain `--enable-sandbox`. |
| P0 | Development renderer was extracted and served by Python over localhost. | Packaged mode is forced with a product-named executable; Electron's secure `app://` scheme loads the ASAR directly. No TCP listener or Python runtime remains. |
| P0 | Shared `~/.codex` state could be opened by Work and Codex concurrently. | Work ignores inherited generic `CODEX_HOME` and owns an isolated XDG data root. Explicit override uses `CHATGPT_WORK_CODEX_HOME`. |
| P0 | Cache/plugin mutation could precede single-instance ownership and lock timeout could continue. | The cold-start lock precedes every prelaunch/cache mutation and timeout fails closed. |
| P1 | A permission repair loop recursively scanned every 100 ms for 30 seconds. | The monitor was removed; startup performs one bounded reconciliation under the lock. |
| P1 | The updater injected periodic polling and package-manager queries. | Both updater descriptors remain auditable but return `skipped-disabled`; package/user transactions own updates. |
| P1 | Hidden prompt/home/thread/Quick Chat windows were prewarmed. | Linux defaults to lazy prompt-window creation unless the user explicitly enables it. |
| P1 | File logs grew without a bound. | stderr/journald is default; the opt-in launcher file rotates at 4 MiB with one predecessor. |
| P1 | Wayland auto mode disabled GPU compositing or fell back to X11. | KDE Wayland selects native Ozone/Wayland with GPU; safe mode remains on Wayland and disables GPU only for recovery. |
| P1 | Installed image duplicated the ~189 MiB renderer and retained ~84 MiB of Node build material. | Duplicate renderer/server, Node headers, npm, Corepack, and build documentation are absent from production output. |
| P1 | Active installs could be deleted before a replacement was known-good. | User installs are checksummed, immutable, content-addressed, atomically switched, and retain one previous release. |

## Current acceptance gates

Every release must pass:

1. exact DMG hash and bounded structural inspection;
2. zero required patch failures and all compatibility regression tests;
3. Electron/native ABI and shared-library validation;
4. no sandbox/TLS/web-security disable switch;
5. exact official-icon provenance and visible unofficial product labeling;
6. native KDE Wayland startup with a standard compositor titlebar;
7. packaged `app://` renderer, no localhost listener, one primary renderer at
   settled idle, and a successful app-server handshake;
8. isolated state, single-instance handoff, safe-mode recovery, clean child
   shutdown, and immutable install rollback;
9. two-core/768 MiB constrained behavior, measured separately for settled base
   shell and one-time primary-runtime installation.

## Next targets

### P0 — release blockers

- Complete interactive live-service QA: Google/email sign-in callback, file
  upload/download, external URL, microphone/camera, screen-share portal,
  screenshot cancellation/success, offline recovery, and permission deny/allow.
- Add an automated post-build ASAR invariant audit for every privileged sender,
  external URL route, download path, and remote webview preload decision.
- Verify the primary-runtime downloader under interruption, hash mismatch,
  disk-full, and 768 MiB pressure; require atomic resume and cleanup of stale
  archives.
- Produce a native Arch package from the already-built immutable tree without
  embedding the source DMG, and inspect it with `pacman -Qkk` after install.

### P1 — robustness and older hardware

- Replace the remaining 3,000-line compatibility launcher with a small typed
  Rust supervisor while preserving the audited argument and recovery behavior.
- Make bundled plugin synchronization version-marker based and fully atomic so
  unchanged cold starts perform no recursive copies.
- Add renderer/app-server crash injection with bounded restart backoff and
  process-group cleanup assertions.
- Record cold/warm start latency, PSS/RSS, renderer count, GPU memory, idle CPU,
  and disk footprint in a repeatable benchmark artifact; prevent regressions.
- Validate software-rendering safe mode on old Intel/AMD drivers and native
  Wayland fractional scaling at 1.0/1.25/1.5/2.0.

### P2 — product integration

- Finish KDE portal flows for global Quick Chat, AppShots, file selection,
  notifications, and computer-use approval without unrestricted global input.
- Add explicit capability diagnostics for browser-use, computer-use, plugins,
  Sites, documents, presentations, and remote control; unavailable features
  should explain the missing dependency rather than silently disappear.
- Build signed repository metadata, reproducible rebuild comparison, SPDX or
  CycloneDX inventory for Linux-added components, and release attestations.
- Add Debian/RPM/AppImage outputs only after the native Arch flow and runtime
  sandbox invariants are identical.

## Non-goals

- No X11 requirement, custom titlebar, Electron sandbox bypass, TLS bypass,
  remote-page shell bridge, polling updater, or unbounded log.
- No imitation of Apple Events, Handoff, macOS Accessibility, Calendar,
  Contacts, or Reminders.
- No publication of the DMG, rebuilt proprietary app, account cookies, or
  official branding without the prominent unofficial disclaimer.

The detailed architecture and exact compatibility evidence are in
[architecture.md](architecture.md) and
[unified-electron-assessment.md](unified-electron-assessment.md).
