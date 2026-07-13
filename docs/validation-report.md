# Validation report

Date: 2026-07-13

Host: Arch Linux x86_64, KDE Plasma/KWin, Wayland

## Verified input and adapter

- Official URL: `https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg`
- HTTP size: 615,738,501 bytes (greater than 500 MiB)
- SHA-256: `c243c94f8de6a51f5530ffe1f8d0c1588733d890ac692e34aaca06d95ba637ca`
- ChatGPT: `26.707.62119`, bundle `5211`, Electron `42.1.0`
- External adapter: `a8dbcb954f6108070b5633afef69792bf12f5507`
- Upstream inventory: 10,777 entries and the browser, chrome,
  computer-use, deep-research, latex, record-and-replay, sites, and visualize
  plugin families.

The adapter's upstream acceptance profile passed all required patches. The
only remaining adapter warning is an optional tooltip collision; it is not a
required runtime capability.

## Build and hardening validation

- A clean `make build` completed from the exact official artifact and current
  cached adapter archive, producing a roughly 949 MiB staged application.
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

Installed doctor output:

```json
{"application":"chatgpt-work-linux","unofficial":true,"runtime":"electron","upstreamVersion":"26.707.62119","electronVersion":"42.1.0","waylandSession":true,"sandboxDisabled":false,"rendererOrigin":"app://","profile":"isolated-xdg"}
```

The verified user release is
`~/.local/opt/chatgpt-work-linux/versions/26.707.62119-9910d47699cdf22f`;
`current` and `previous` are immutable releases. Its Computer Use backend
SHA-256 is `7dabf671ba4599a29c3153f8cfc4b08b1a0c47aded9397c4c989e5cd57dfe863`.
The unrelated
`chatgpt-desktop-linux` wrapper and its dedicated profile/desktop residue were
removed. The separate Codex desktop installation was not changed.

## Remaining interactive release coverage

An entitled account should still exercise authentication, offline recovery,
external links, uploads/downloads, microphone and screen permissions, Quick
Chat, Sites, scheduled work, computer-use confirmation/cancellation, restart,
and rollback. These service- and permission-dependent flows cannot be fully
proved by a clean-profile process smoke test.
