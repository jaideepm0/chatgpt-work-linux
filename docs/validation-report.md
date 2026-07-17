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
  cached adapter archive, producing a 763 MiB staged application.
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
- The same byte-stable patch step changes the final Computer Use host predicate
  from macOS/Windows to Linux/Windows for this Linux-only artifact and resolves
  its otherwise unavailable rollout/feature inputs to fixed Linux build values.
  The user-enabled flag, platform readiness, Electron context, and platform
  predicate remain enforced. Exact anchor and byte-length checks prevent silent
  renderer drift.
- Native shared libraries resolved, the managed Node runtime reported v22, and
  required shell/desktop/AppStream validations passed.
- Chromium's documented reduced-motion preference is requested by default.
  In the same virtual-Wayland/two-core 30-second A/B profile, settled CPU fell
  from 88.44% to 5.05%; renderer CPU fell from 58.05% to 0.96%. This is a
  command-line preference rather than a renderer or style patch, and users can
  explicitly request full motion in `electron-flags.conf`.

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
- clean launch and teardown using temporary XDG state.

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
`~/.local/opt/chatgpt-work-linux/versions/26.715.21425-aab24be426347a9c`;
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
