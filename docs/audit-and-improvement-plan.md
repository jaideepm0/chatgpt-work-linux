# Reference audit and improvement plan

> **2026-07-10 architecture update:** the newly supplied 561,015,842-byte
> `ChatGPT-work.dmg` is ChatGPT `26.707.31428`, a unified Electron 42
> ChatGPT/Codex application, rather than the prior Apple-only Swift client.
> The WebKit plan below is retained as the completed historical baseline and as
> the architecture of `chatgpt-desktop-linux`. The active Work architecture,
> compatibility failures, security gates, and performance plan are in
> [unified-electron-assessment.md](unified-electron-assessment.md).

## Scope and verified baseline

The reference repository was audited read-only at commit
`f3836c9c225cb0a2868f05bf0bc031f20c57c56f`. Its shell syntax checks passed,
as did 329 main-patcher tests and 379 optional-feature tests. The target host is
Arch Linux x86_64 on KDE Wayland with GTK 3/4, WebKitGTK 2.52, PipeWire, XDG
portals, Rust 1.96, and native pacman packaging tools.

The previously observed official macOS artifact was independently fetched from the URL
linked by OpenAI's [desktop download page](https://chatgpt.com/features/desktop/)
and recorded in [upstream-snapshot.json](upstream-snapshot.json). It is ChatGPT
`1.2026.183`, build `1783607847`, commit `3dab2ed0d5`, SHA-256
`49b33cadd2ec659b76352384f7ebd332a7ec7029663365a9f720f4a251d3b8d1`.
The main application is an ARM64 Mach-O native macOS binary; no Electron marker
or ASAR exists. OpenAI's own [requirements article](https://help.openai.com/en/articles/9275200)
requires Apple Silicon and macOS 14. At that observation point, binary
translation or the reference repository's Electron replacement technique was
not a viable Linux architecture. That conclusion is superseded for Work by the
new unified Electron artifact.

## Findings in `codex-desktop-linux`

The reference has several patterns worth preserving: separated acquisition /
patch / staging / packaging phases; deterministic descriptor ordering; build
provenance and patch reports; XDG state separation; warm-start handoff; atomic
updater state; rollback primitives; optional feature manifests; Nix hash pins;
and broad test coverage.

The following problems should not be carried into this project. Paths and line
numbers refer to the audited reference commit.

| Priority | Finding and evidence | Design response here |
|---|---|---|
| P0 | A normal fresh install deletes the active app before the replacement succeeds (`scripts/lib/install-helpers.sh:161`; `Makefile:191`). | User installs stage an immutable content-hashed version, verify it, atomically switch `current`, and retain `previous`. Native package transactions are delegated to pacman. |
| P0 | Every Electron launch disables the Chromium and GPU sandboxes (`launcher/start.sh.template:2780`). | WebKit stays in its bubblewrap/seccomp process model. Chromium fallback never passes `--no-sandbox`, disables TLS checks, or changes `webSecurity`. |
| P0 | Mutable downloads and cached Electron archives lack a trusted manifest; `npx` and npm tools can be fetched live (`scripts/lib/dmg.sh:128,425`; `scripts/lib/native-modules.sh:8,286`). | Ordinary builds never fetch the proprietary DMG. Cargo.lock is committed. The optional fetcher has an exact URL allowlist, HTTPS, time/size bounds, ETag-aware atomic resume, archive validation, and a deterministic provenance report. |
| P0 | Optional patch misses can leave enabled features partially staged; the current report has 13 optional skips. | No upstream code patching exists. Native features are typed Rust modules; remote content receives no native IPC bridge. Future optional features must fail closed and have explicit capability scopes. |
| P0 | Shared plugin/webview caches are rewritten before the startup lock (`launcher/start.sh.template:3014,3064,3090`), and the launcher can proceed after lock timeout. | GTK/GApplication owns one instance per validated profile before any browser state is opened. WebKit owns its transactional website store; no runtime cache seeding or `rm/cp` repair loop exists. |
| P1 | A 30-second permission monitor performs two recursive `find` walks every 100 ms, while plugins are recopied on cold starts (`launcher/start.sh.template:336,1090`). | No polling, recursive scan, cache copy, or plugin mutation is performed on startup. Portal events and WebKit signals are event-driven. |
| P1 | The updater wakes every 15 seconds and spawns package-manager queries (`updater/src/app.rs:27,397,1004`; `install.rs:169`). | There is no resident updater. The web surface updates server-side and Linux binaries update through explicit package/user-install transactions. |
| P1 | Launcher and updater logs append forever; an observed launcher log was about 91 MB (`launcher/start.sh.template:269`; `updater/src/logging.rs:7`). | Runtime logs go to stderr/journald. The project creates no append-only log file containing page or conversation data. |
| P1 | A sampled package expands past 1.2 GB, duplicates two ~197 MB Node runtimes, keeps ~946 MB backups, and installs compiler dependencies (`scripts/lib/package-common.sh:728`). | The runtime is one stripped Rust binary using shared system GTK/WebKit. User installs retain at most current and previous binaries. Build tools are package-time dependencies only. |
| P1 | Native modules rebuild on every run, build parallelism is unbounded, a 530 MB DMG is read into memory, and child output is fully buffered (`native-modules.sh:173`; `build-info.js:239`; `updater/src/builder.rs:500`). | There are no native Node modules. The DMG inspector hashes by streaming and extracts only bounded metadata candidates. Release builds target the generic architecture, use thin LTO, and can be resource-capped externally. |
| P1 | Web assets are served with `no-store`, defeating immutable caching (`launcher/webview-server.py:41`). | The public service and WebKit control standards-compliant HTTP caching; there is no local web server. |
| P1 | Renderer accessibility is forced for most sessions (`launcher/start.sh.template:2537`). | Accessibility follows GTK/AT-SPI and the user's desktop. It is not forcibly enabled by a Chromium flag. |
| P1 | The 3,103-line shell launcher acts as a process supervisor. | Startup, policy, liveness, downloads, permissions, and diagnostics are typed Rust modules. Shell is restricted to build/install orchestration. |
| P1 | Config writes race and interval values are insufficiently validated (`updater/src/config.rs:159,300`; `app.rs:397`). | Config is read-only during runtime, rejects unknown keys, validates HTTPS and window limits, and falls back without overwriting malformed user data. |

## Latest upstream and supply-chain implications

The official [ChatGPT Work page](https://chatgpt.com/work/) describes Work as an
agent that gathers context, creates artifacts, schedules/monitors work, and asks
for permission before actions. The [unified download page](https://chatgpt.com/download/)
states that existing Codex app users can update to ChatGPT and open Codex. The
Linux shell consequently treats the official web product as the feature source
of truth rather than recreating those rapidly changing capabilities locally.

OpenAI's April 2026
[Axios compromise report](https://openai.com/index/axios-developer-tool-compromise/)
documents a compromised dependency entering a macOS signing workflow, a
rotated certificate, and remediated ChatGPT builds from `1.2026.051`. The
observed `1.2026.183` is newer, but the incident reinforces these rules:

- Commit dependency locks; do not install unpinned build tools during a build.
- Pin CI actions to immutable commits when CI is added.
- Quarantine newly published dependencies and review exceptions.
- Produce package checksums/SBOM/provenance before public release.
- Treat the mutable official download URL as an observation source, not a
  versioned trust root; perform final Apple signature/notarization checks on
  macOS when refreshing the reference.

OpenAI's current [Terms of Use](https://openai.com/policies/terms-of-use/)
prohibit modifying/distributing the Service and reverse engineering underlying
components. The DMG is therefore reference material: it is ignored and its
binaries are never executed, patched, or bundled. The only included artifact
is the unmodified public ChatGPT app icon requested for desktop identification,
with hash provenance and OpenAI ownership recorded. The installed app is
clearly labeled as a community project.

## Prioritized roadmap

Implemented now:

1. Lightweight WebKit runtime plus Chromium/browser fallbacks.
2. Single-instance profile isolation, strict URL policy, permission mediation,
   downloads, notifications, crash backoff, offline feedback, and safe mode.
3. Portal global shortcut and interactive screenshot-to-clipboard flow.
4. Deterministic upstream provenance tooling and snapshot.
5. Unit/tooling tests, standard compositor decorations, native menus/settings,
   verified immutable user installs, and checksummed Arch packaging.
6. Google OAuth detection and user-approved whole-profile Chromium handoff;
   cookies are never copied between engines.
7. Adaptive WebKit page caching and supported memory-pressure limits for
   efficient/low-memory sessions.

Next release candidates:

1. KDE Wayland production CI/smoke coverage plus an X11 compatibility lane,
   with mocked first-party pages, media permission tests, web-process crash
   injection, and resource budgets. A host-side Wayland/cgroup/single-instance
   smoke harness is implemented; CI, mocked pages, and X11 remain.
2. Screenshot/file drag-to-composer support only if a stable browser API makes
   it possible without DOM automation.
3. Explicit IDE integration with context preview, byte/line limits, diff
   approval, and no background accessibility scraping.
4. Signed package repositories, SBOM, reproducible-build comparison, and
   release provenance. Reproducible CycloneDX 1.5 generation and native-package
   inclusion are implemented; signing, repository publication, and independent
   rebuild comparison remain.
5. Work capability parity in reviewed slices: explicit local-file context,
   browser integration, IDE context/diff review, and scheduled-work desktop
   notifications. Every slice requires a supported service surface, a visible
   preview, per-action approval, byte/time limits, and a fail-closed policy.

Completed after the native baseline:

1. Canonical desktop/portal identity and a least-privilege GNOME 50 Flatpak
   manifest with locked, checksummed, offline Cargo sources and a documented
   sandbox/authentication audit.
