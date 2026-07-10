# Unified ChatGPT artifact assessment

## Decision

The Work application will move from the Rust/WebKit public-web shell to a
Linux-native rehost of the portable Electron application plane in the unified
ChatGPT desktop release. The prior implementation remains recoverable at the
annotated tag `rust-webkit-baseline-v0.1.0`, and the independently installed
`chatgpt-desktop-linux` remains the lightweight public `chatgpt.com` client.

This is an evidence-backed exception to the original WebKit-first architecture:
the new artifact is no longer the Apple-only Swift application previously
inspected. It contains an Electron 42.1.0 application, a 194,935,447-byte ASAR,
portable webview assets, the Codex app-server, plugins, skills, browser-use
resources, and native modules. Rehosting this application plane is the only
reviewed route to the actual Work product rather than another web wrapper.

The build is still an unofficial local compatibility project. It must not
publish the DMG or claim OpenAI endorsement. OpenAI owns the ChatGPT name, icon,
application resources, and service. The About surface, package metadata, and
README must remain visibly labeled as unofficial.

## Exact observed input

| Field | Observation |
|---|---|
| Local file | `ChatGPT-work.dmg` |
| Size | 561,015,842 bytes |
| SHA-256 | `6f67af7e2f934093ab8afebcec11374d40c8db8f9100fb6620f24155401d8319` |
| Volume | `ChatGPT-26.707.31428-arm64` |
| Display/version | ChatGPT `26.707.31428` (bundle `5059`) |
| Bundle identifier | `com.openai.codex` |
| Implementation | Electron 42.1.0 / Chromium 150 |
| Application ASAR | 194,935,447 bytes |
| Entries | 10,777 |
| URL scheme | `codex` |

The file is byte-for-byte identical to the current `Codex.dmg` reference in
the sibling `codex-desktop-linux` checkout. OpenAI now ships the same unified
ChatGPT/Codex desktop lineage under the ChatGPT product surface. The old claim
that a 500+ MiB file must be a separate product is no longer true.

The exact structural inventory is recorded in
[upstream-snapshot.json](upstream-snapshot.json). No Mach-O executable was run.

## Capability inventory

The artifact contains local product surfaces that the public ChatGPT web shell
cannot reproduce faithfully:

- multi-agent threads, worktrees, diff review, terminal sessions, and local
  app-server lifecycle;
- plugins and skills, including browser-use, computer-use, record/replay,
  appshots, sites, and visualization resources;
- document, presentation, and workbook rendering assets and WASM runtimes;
- remote connections, mobile steering, browser annotations, scheduled work,
  conversation/read-aloud surfaces, and native desktop actions;
- a bundled Codex CLI and code-mode host.

Availability remains controlled by the signed-in account, server flags,
platform capability checks, and Linux compatibility policy. Merely observing a
bundle is not a promise that every feature is enabled.

## Compatibility audit against `codex-desktop-linux`

The reference patcher recognized Electron 42.1.0 and successfully applied or
recognized 91 patches. It also reported five required failures and 27 optional
or warning outcomes. A production build must not silently ship through these
gaps.

Required failures on `26.707.31428`:

1. `linux-window-options`: the primary `BrowserWindow` appearance alias moved.
2. `linux-native-titlebar`: the previous titlebar snippet no longer exists.
3. `linux-avatar-overlay-mouse-passthrough`: the interactivity policy changed.
4. `linux-tray`: the prior fallback marker moved.
5. `main-process-ui`: aggregate failure caused by the window-options miss.

The new renderer also moved several settings, remote-control, AppShots, model,
and action-modal bundles. These are drift signals, not permission to guess at
minified replacements. Every required patch needs a semantic invariant and a
fixture from the exact new bundle. Optional features must either validate or be
explicitly disabled in the build report.

## Selected architecture

```text
local DMG (exact hash, developer input only)
            |
            v
bounded extractor -> structural validator -> deterministic patch engine
            |                    |                     |
            |                    |                     +-> required drift = stop
            |                    +-> capability/provenance report
            v
portable upstream UI + Linux app-server/resources
            |
            v
verified Electron 42 runtime + native modules built at package time
            |
            v
small Linux supervisor / launcher
  - profile lock before shared state
  - Wayland-first Ozone selection
  - standard compositor titlebar
  - Chromium sandbox retained
  - bounded diagnostics to stderr/journald
  - no updater daemon or runtime compiler/download
```

The mature deterministic patch engine and its regression suite from
`codex-desktop-linux` are the compatibility base. The launcher and packaging
path are not adopted unchanged. In particular, this project will remove the
reference launcher's unconditional `--no-sandbox` and
`--disable-gpu-sandbox`, local Python HTTP server, startup-time native builds,
unbounded file logs, and polling updater.

Static webview assets should be served through an Electron custom protocol
registered as privileged before `app.ready`, with a strict content security
policy, immutable cache headers, traversal-safe path resolution, and no TCP
listener. Remote pages receive no preload or native IPC bridge. IPC handlers
are restricted to the packaged local renderer and validated message schemas.

## Security and robustness gates

- Fail the build on every required patch miss, ambiguous match, unexpected
  ASAR path, hash mismatch, unsafe archive path, or native-module ABI mismatch.
- Retain Chromium's renderer and GPU sandboxes. Package `chrome-sandbox` with
  the platform-required ownership/mode or require supported user namespaces;
  never fall back to `--no-sandbox`.
- Acquire the profile-scoped single-instance/lock before cache repair,
  migration, app-server startup, or webview serving.
- Bind privileged native actions only to the packaged local origin. Treat
  `https://chatgpt.com` and every other remote origin as untrusted content.
- Use portals for Wayland capture, file selection, opening external resources,
  notifications, and global shortcuts where applicable.
- Do not run npm/npx, compile native modules, download Electron, or recopy
  plugins during ordinary launch.
- Disable Sparkle and in-app self-update surfaces; update only through explicit
  package/user-install transactions with rollback.
- Send bounded diagnostics to stderr/journald. Never append conversation,
  cookie, prompt, or token data to a file log.

## Performance strategy

The actual Work product cannot meet the old 20 MiB WebKit-shell budget, but it
can be materially leaner and more predictable than the current reference port:

- one Electron and one Node/app-server runtime, no duplicate backups or build
  toolchain in the installed image;
- native modules prebuilt for Electron 42 and stripped at package time;
- immutable ASAR/web assets, no per-launch extraction or plugin copying;
- event-driven lifecycle instead of 100 ms permission scans and 15-second
  updater polling;
- lazy start for browser-use, computer-use, appshots, document runtimes, and
  auxiliary windows;
- bounded app-server restart backoff and child process groups cleaned on exit;
- Ozone Wayland by default, with automatic GPU recovery and an explicit safe
  mode rather than permanent GPU disablement;
- generic x86-64 output without `target-cpu=native` or AVX-only assumptions.

Acceptance includes cold/warm startup, idle CPU/RSS, renderer count, app-server
liveness, shutdown cleanup, offline recovery, single instance, OAuth callback,
file/portal flows, and repeated crash/restart tests. A constrained lane uses two
cores and 768 MiB; features that inherently exceed it must degrade visibly and
without corrupting state.

## Official product evidence

OpenAI's current [ChatGPT release notes](https://help.openai.com/en/articles/6825453-chatgpt-release-notes)
describe AppShots, goal mode, browser improvements, remote/mobile control, and
the Codex desktop host. OpenAI's
[Codex introduction](https://openai.com/index/introducing-the-codex-app/)
describes the desktop app as a command center for parallel agents and long
running work. Those public descriptions align with the local bundle inventory
and are the acceptance target; undocumented private service behavior is not.

