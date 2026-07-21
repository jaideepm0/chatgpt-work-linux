# Validation report

Date: 2026-07-17

Host: Arch Linux x86_64, KDE Plasma/KWin, Wayland

## Verified input and adapter

- Official URL: `https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg`
- HTTP size: 618,657,103 bytes (590 MiB; greater than 500 MiB)
- SHA-256: `ff459150991612007549270d2d28c5e78cec6bd6ac200a7ada5ed6c031369b87`
- ChatGPT: `26.715.21425`, bundle `5488`, Electron `42.3.0`
- External adapter: `b24e5ff2cfabbd1a366f711229b3b115aa4397fe`
- Upstream inventory: 10,778 entries and the browser, chrome,
  computer-use, deep-research, latex, record-and-replay, sites, and visualize
  plugin families.

The adapter's upstream acceptance profile passed all required patches. Eight
upstream-drift warnings remain optional: About icon fallback, avatar-settings
sync, Chrome-extension status, eager automation tool loading, monospace font
fallback, tooltip collision, Browser sidebar attachment recovery, and the
Sparkle updater bridge. None changes the renderer origin, Codex task database,
sandbox, or required Computer Use capability.

## Build and hardening validation

- A clean `make build` completed from the exact official artifact and current
  cached adapter archive, producing a 765 MiB staged application.
- The generated build contains `chatgpt-work-linux-bin`, the packaged renderer,
  app-server, plugins, rebuilt Linux native modules, provenance reports, and a
  complete SHA-256 manifest.
- Build assertions proved the launcher contains no `--no-sandbox`,
  `--disable-gpu-sandbox`, localhost renderer export, or packaged Python asset
  server.
- The Electron executable identity makes `app.isPackaged=true`; the renderer
  loads from `app://` instead of the development `http://localhost:5175` URL.
- An exact, same-length ASAR patch removes only the unconditional Linux startup
  Quick Chat prewarm. This eliminates the second blank startup window without
  changing ASAR offsets or removing on-demand Quick Chat.
- The same fail-closed patch connects tray startup to its persisted default-on
  setting and treats the absence of the official runtime's private
  `Tray.whenReady()`/`Tray.isReady()` extensions as success. Stock Electron's
  public Tray constructor is synchronous and chooses StatusNotifierItem before
  its standard legacy Linux fallback; no desktop-specific tray backend was
  added.
- The same byte-stable patch step changes the final Computer Use host predicate
  from macOS/Windows to Linux/Windows for this Linux-only artifact and resolves
  its otherwise unavailable rollout/feature inputs to fixed Linux build values.
  The user-enabled flag, platform readiness, Electron context, and platform
  predicate remain enforced. Exact anchor and byte-length checks prevent silent
  renderer drift.
- Native shared libraries resolved, the managed Node runtime reported v22, and
  required shell/desktop/AppStream validations passed.
- Chromium's documented reduced-motion preference is requested by default.
  This is a command-line preference rather than a renderer or style patch, and
  users can explicitly request full motion in `electron-flags.conf`. Upstream
  already leaves normal hidden-window background throttling enabled and
  dynamically throttles inactive Browser views, so the compatibility layer
  does not add redundant lifecycle hooks or speculative Chromium switches.

Repeated final two-core profiles show the cost and variability of the complete
signed-in unified surface honestly: cold ready 3.071-14.251 seconds, second
process-tree ready 3.068-11.453 seconds, live warm handoff 0.526-0.805 seconds,
9 processes, settled PSS 923.6-1,117.4 MiB, peak PSS 1,169.7-1,180.2 MiB, and
settled aggregate CPU 1.98-51.78%. The detailed quiescent sample attributed
1.98% CPU to the Codex app-server and 0.50% to the renderer. Account/catalog
background work caused the high sample; it is not relabeled as idle.

The strict 768 MiB cgroup lane does not pass: the kernel OOM-killed the final
profile at the configured 768 MiB peak while loading the unified renderer,
app-server, plugins, and 888-thread sidebar. This is recorded as an unresolved
upstream memory limit, not hidden as a successful gate. No unsafe V8 heap cap,
sandbox reduction, or feature removal was applied to manufacture a pass.

Computer Use release validation additionally requires the Linux UI feature,
plugin gate, native desktop-app discovery, renderer availability, and install
flow patches to report `applied` or `already-applied`. A `skipped-disabled`
status for any of them now fails the build.

The Linux backend is additionally compiled with a local, exact-source Wayland
hardening pass. Pointer and keyboard actions prefer the consented Remote
Desktop portal, direct uinput is disabled on Wayland, and any `ydotool`
fallback fails closed there. Targeted `press_key` and portal `type_text`
revalidate focus after portal-session setup immediately before injection;
targeted text avoids the KDE clipboard path so clipboard preparation cannot
create a focus race. The transform is idempotent and rejects missing or
ambiguous anchors.

The outer build treats a missing executable/manifest, failed backend
self-check, or missing compiled portal-only guard as fatal because the external
adapter currently treats a native Computer Use compile failure as a non-fatal
warning.

## Runtime validation

The isolated Wayland smoke test passed and observed:

- Electron main process on `--ozone-platform=wayland`;
- one sandboxed renderer with `--enable-sandbox` and `app://` origin;
- no sandbox-disable arguments and no local HTTP asset-server process;
- `packaged=true platform=linux` in application diagnostics;
- successful app-server handshake and primary-frame readiness;
- successful Computer Use MCP initialize and `tools/list` handshake with
  pointer, keyboard, text, screenshot, accessibility, and window tools;
- Computer Use doctor selecting `portal` for input and screenshot, `kwin` for
  exact window control, and `at_spi` for accessibility with no blockers;
- clean launch and teardown using temporary XDG state;
- a freedesktop StatusNotifierItem whose D-Bus owner PID was the tested
  Electron main process;
- a bounded warm-start IPC handoff that preserved the Electron PID and avoided
  a second renderer/app-server tree.

Interactive KWin validation showed the unified product—not the public Work
marketing page—with Chat, Codex/New task, Scheduled, Plugins, Sites, pull
requests, projects, and the native task composer. The Computer Use plugin now
renders as available without the `Unavailable in this context` label. A portal
text-input probe and a portal key chord both completed successfully. The final
backend adds last-moment target-focus revalidation after a focus-race was
observed during testing. The blank overlay did not reappear.

Local Codex history validation used a consistent database and Electron-profile
clone. The former launcher had split history into 884 canonical threads and 4
isolated threads with no overlapping IDs. The migration tool backed up the
canonical database, copied 6 required rollout/shell-snapshot files, merged the
4 thread and index records transactionally, rewrote rollout paths, and passed
SQLite `quick_check`. The unified sidebar then rendered Chat/Work projects and
888 local Codex threads together. One recovered 4-turn thread and one prior
2-turn thread both completed `thread/read` and resume successfully. Eight
headerless, one-message rollout stubs from 2025 and one empty rollout from May
2026 remain preserved on disk but are intentionally not forced into the
official index.

Installed doctor output:

```json
{"application":"chatgpt-work-linux","unofficial":true,"runtime":"electron","upstreamVersion":"26.715.21425","electronVersion":"42.3.0","waylandSession":true,"sandboxDisabled":false,"rendererOrigin":"app://","profile":"xdg-electron+canonical-codex"}
```

The verified user release is
`~/.local/opt/chatgpt-work-linux/versions/26.715.21425-f388d7a8a520685d`;
`current` and `previous` are immutable releases. Its Computer Use backend
SHA-256 is `f06f368779f907e1ada57231b8b222cd21668935adbc83a9faac5fd8ef6306e0`.
The unrelated
`chatgpt-desktop-linux` wrapper and its dedicated profile/desktop residue were
removed. The separate Codex desktop installation was not changed.

## Remaining interactive release coverage

An entitled account should still exercise authentication, offline recovery,
external links, uploads/downloads, microphone and screen permissions, Quick
Chat, Sites, scheduled work, computer-use confirmation/cancellation, restart,
and rollback. These service- and permission-dependent flows cannot be fully
proved by a clean-profile process smoke test.

## 2026-07-18 resource-regression audit

The two July 17 commits were compared with the July 13 baseline. The worktree
was clean before this audit. Historical evidence shows that the unified
Electron runtime was already heavy (about 1.3 GiB aggregate RSS), while the
new default-on tray lifecycle made that cost persist after the last window was
closed. A fresh-profile comparison measured 803-830 MiB settled PSS, showing
that the 888-thread canonical history increases the signed-in result but is
not the sole cause of the footprint.

The source now makes tray, warm-start socket, and prompt-window lifecycle
features explicit opt-in while retaining canonical Codex history and native
Electron second-instance reuse. The profiler's process-churn accounting was
also corrected so an exiting child cannot produce negative aggregate CPU.

During rebuild, the mutable official URL published version `26.715.31251`
(618,656,313 bytes) in place of the reviewed `26.715.21425` snapshot. The old
fetcher inspected and published that unreviewed artifact into the private
cache before the build rejected it. Acquisition now validates the checked-in
size/hash/version before cache publication; only the explicit snapshot-refresh
transaction may inspect an unreviewed candidate. Static, unit, upstream-tool,
and runtime-hardening checks pass. A rebuilt runtime profile remains pending
until the new upstream artifact and adapter drift are explicitly reviewed.

The improved per-process profiler measured the still-installed reviewed build
at 1,151.0 MiB settled PSS, 1,688.2 MiB RSS, nine processes, 2.46% aggregate
CPU on two permitted cores, and 754.4 MiB generated size after a 20-second
settle. PSS attribution was 466.0 MiB renderer, 326.1 MiB Electron main,
197.1 MiB combined Node/Codex app-server, 101.3 MiB GPU, and 60.5 MiB Chromium
network/zygote infrastructure. This profile validates measurement changes, not
the unbuilt lifecycle patch.

The automated 768 MiB lane initially exposed an invalid measurement condition:
Plasma re-scoped the mapped Wayland Electron tree out of the transient limited
cgroup and into `app-io.github.chatgpt_work_linux-*.scope`. The profiler now
validates that exact compositor-created destination, moves the complete tree
back into the original runner scope, and rechecks containment. A clean candidate
build of `26.715.61943` at source commit `5c14c27` remained contained but the
kernel OOM-killed its warm run at exactly 768 MiB. Candidate promotion and local
installation therefore remain blocked; the reviewed installation and its
authenticated profile were not changed.

Because a valid failure still invokes the kernel OOM killer and can produce a
desktop low-memory notification, constrained profiling now requires explicit
per-invocation consent and a host-available-memory preflight. Failure paths emit
bounded cgroup counters and sanitized process memory roles before cleanup.
