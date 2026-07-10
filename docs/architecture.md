# Production architecture

## Decision

`chatgpt-work-linux` is a deterministic Linux rehost of the portable Electron
application plane in the user-supplied ChatGPT Work `26.707.31428` artifact.
It is not a `chatgpt.com` wrapper and it does not execute the Mach-O binaries.
The prior Rust/WebKit shell is preserved at
`rust-webkit-baseline-v0.1.0` and as the separate
`chatgpt-desktop-linux` application.

The current artifact contains Electron 42.1.0, a portable ASAR, the unified
Work renderer, app-server integration, plugins, browser/computer-use, Sites,
AppShots, scheduled tasks, and document runtimes. Rebuilding that application
plane is the smallest architecture that delivers product parity.

## Build and runtime flow

```text
user-supplied DMG (exact SHA-256)
       │
       ▼
bounded APFS extraction ──► structural/provenance report
       │
       ▼
deterministic compatibility descriptors
  required drift => stop; optional drift => explicit report/disable
       │
       ▼
Electron 42 Linux runtime + prebuilt native modules + patched ASAR
       │
       ├── secure packaged app:// renderer
       ├── standard KWin/compositor titlebar
       ├── sandboxed Chromium renderers/GPU process
       ├── isolated XDG Work profile
       ├── local Codex app-server and lazy feature runtimes
       └── native Wayland/Ozone, portals, file and permission mediation
```

The build output is immutable. `install-user.sh` copies it to a
content-addressed version, validates every file, changes it read-only, then
atomically switches `current` while retaining `previous`. A failed build or
copy never replaces the active install.

## Security boundaries

1. The local privileged renderer is loaded only from Electron's registered
   `app://` protocol. `ELECTRON_RENDERER_URL` is cleared. No local HTTP server,
   TCP port, Python runtime, or mutable development origin exists.
2. Chromium's renderer and GPU sandboxes remain enabled. The launcher rejects
   `--no-sandbox` and `--disable-gpu-sandbox` at build time and never disables
   TLS verification, CSP, or web security.
3. The patched main process validates privileged senders and keeps remote
   browser/webview content outside the local renderer trust boundary. Native
   actions use explicit schemas and platform checks.
4. Work owns `${XDG_DATA_HOME}/chatgpt-work-linux/codex-home` and matching
   config/cache/state roots. A generic inherited `CODEX_HOME` is ignored so a
   terminal, Codex app, and Work cannot concurrently mutate one profile.
5. The launcher acquires its single-instance lock before prelaunch hooks,
   plugin/cache reconciliation, app-server startup, or browser state. Lock
   timeout fails closed.
6. In-app polling updates are disabled. Updates are explicit local builds and
   atomic installation transactions. Runtime diagnostics default to
   stderr/journald; optional files rotate at 4 MiB with one predecessor.
7. The proprietary artifact and rebuilt application are local inputs/outputs
   and remain Git-ignored. Only audit metadata and the specifically requested
   official icon are committed, with an ownership disclaimer.

## Wayland and desktop integration

KDE Wayland is the primary platform. Ozone is set to `wayland`, GPU compositing
stays enabled, and Electron requests Wayland window decorations. KWin owns the
titlebar, shadows, scaling, focus, movement, and resizing. `--safe-mode` keeps
the active Wayland protocol and disables GPU acceleration; `--x11` remains an
explicit diagnostic fallback, not a requirement.

File selection, screen sharing/capture, notifications, external URLs, and
global input capabilities use Electron/Chromium's Linux integration and XDG
portals where supported. Portal operations remain user initiated.

## Performance model

The unified Work product is much heavier than the web-shell baseline, but the
Linux port removes avoidable overhead:

- the ASAR's own `app://` renderer replaces a duplicated ~189 MiB extracted
  webview and Python loopback server;
- prompt, home, thread, and Quick Chat windows are created lazily instead of
  prewarming three hidden Chromium renderers;
- recursive 100 ms permission monitoring and 30-second updater polling are
  removed;
- only one managed Node executable and `node_repl` remain; build headers, npm,
  Corepack, and documentation are pruned after native module compilation;
- Wayland GPU compositing is the default, avoiding permanent software
  rendering and unnecessary framebuffer traffic;
- generic x86-64 output is retained with no `target-cpu=native` or AVX-only
  assumptions.

Base-shell measurements are separated from the one-time installation of the
~405 MiB compressed primary Linux runtime. Runtime extraction can temporarily
exceed the 768 MiB constrained lane; it must fail cleanly and resume rather
than corrupting the profile. Once installed, idle acceptance requires one
visible primary renderer, no hidden Quick Chat renderer, no polling helper,
and no leaked child after exit.

## Failure and recovery

- Exact hash mismatch, unsafe extraction, missing required patch, ambiguous
  patch match, native ABI failure, missing shared library, icon mismatch, or a
  sandbox-disable flag stops publication.
- Native module builds happen at build time, never at ordinary launch.
- The app-server uses the current official Codex CLI and the application's
  bounded restart behavior. Browser/computer-use and primary runtimes are
  started lazily.
- `--safe-mode` is the first GPU recovery route. User data is separate from the
  immutable binary, so rollback does not roll back or erase conversations.
- `doctor --json` reports packaged runtime, Wayland, Codex CLI, sandbox policy,
  renderer origin, and profile isolation without loading the GUI.

The exact artifact/patch analysis and remaining drift are recorded in
[unified-electron-assessment.md](unified-electron-assessment.md).
