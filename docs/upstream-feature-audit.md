# Unified ChatGPT feature audit

Date: 2026-07-13

## Provenance

| Field | Observation |
|---|---|
| Official artifact | `https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg` |
| Version/build | `26.707.62119` / `5211` |
| Size | 615,738,501 bytes |
| SHA-256 | `c243c94f8de6a51f5530ffe1f8d0c1588733d890ac692e34aaca06d95ba637ca` |
| Bundle/runtime | `com.openai.codex`, Electron 42.1.0 |
| Adapter | `a8dbcb954f6108070b5633afef69792bf12f5507` |

The snapshot was produced by bounded structural inspection. No Mach-O binary
was executed. Exact component and privacy-key inventories are recorded in
`upstream-snapshot.json`.

## Observed application surfaces

- Chat history, projects, tasks, files, model/account settings, and voice/read
  aloud resources.
- Work/Codex task composer, repositories, worktrees, diffs, terminal sessions,
  pull requests, remote environments, steering, and scheduled work.
- Plugins for browser, Chrome, computer use, deep research, LaTeX,
  record/replay, Sites, and visualization.
- Document, spreadsheet, presentation, image, and PDF rendering resources.
- Quick Chat/hotkey windows, notifications, update UI, mobile/remote-control,
  browser annotations, and app-server authentication flows.

An observed resource is not proof that the signed-in account is entitled to
it or that every platform capability is enabled. Runtime acceptance must be
reported separately from structural presence.

## Computer-use and desktop integration

The adapter contains Linux implementations for portal screenshots, AT-SPI
observation, window discovery/focus, browser control, and input actions, with
feature manifests that distinguish required, optional, disabled, and skipped
patches. These are privileged capabilities and must remain behind the local
packaged application plane and explicit user interaction. They must never be
exposed to ordinary remote web content.

For the current build:

- Wayland is the supported compositor path; X11-specific compatibility work is
  outside the requested release scope.
- The Chromium sandbox remains enabled.
- The generated localhost renderer server is removed.
- Quick Chat is lazy rather than prewarmed at startup.
- Wayland input is portal-only; direct uinput/`ydotool` paths are disabled and
  targeted keyboard actions recheck compositor focus immediately before input.
- Portal denial/cancellation and missing optional capabilities must fail
  visibly without weakening sandbox, TLS, or origin checks.

## Acceptance matrix

| Area | Automated evidence | Interactive evidence still required |
|---|---|---|
| Renderer | `app://`, `app.isPackaged=true`, sandboxed renderer | navigation and offline recovery |
| App server | handshake succeeds | authenticated task lifecycle |
| Windowing | Wayland Ozone, one startup renderer | Quick Chat/toggle/multi-monitor |
| Files | packaged resources and native modules validated | upload/download and portal cancellation |
| Media | PipeWire/portal dependencies present | microphone/screen allow and deny |
| Work | unified UI visually present | account-entitled tasks, Sites, schedules |
| Computer use | plugin and Linux adapter present | preview, consent, cancellation, emergency stop |

Required patch drift is a build failure. Optional drift is retained in the
report and reviewed for each upstream version.
