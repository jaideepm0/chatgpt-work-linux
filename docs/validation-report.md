# Validation report

Date: 2026-07-10

Host: Arch Linux x86-64, KDE Plasma/KWin, native Wayland

## Artifact and build gates

- Input: `ChatGPT-work.dmg`, 561,015,842 bytes, SHA-256
  `6f67af7e2f934093ab8afebcec11374d40c8db8f9100fb6620f24155401d8319`.
- Detected ChatGPT `26.707.31428` build `5059`, Electron `42.1.0`.
- APFS extraction completed with nine known safe package-symlink repairs; no
  unsafe archive path was accepted and no Mach-O executable was run.
- Required patch gate: 12 applied, 5 already applied, zero required failures.
  Optional core: 32 applied, 11 already applied, 7 explicitly skipped, 4
  disabled, and 1 target-inapplicable.
- All 329 general compatibility tests and four exact `26.707` semantic tests
  passed. The preserved Rust baseline passed formatting, Clippy with warnings
  denied, 24 Rust tests, and adversarial provenance-tool tests.
- Native `better-sqlite3` and `node-pty` modules compiled for Electron ABI 146
  with generic `-march=x86-64 -mtune=generic`; shared-library validation found
  no unresolved dependency.
- The build contains no launcher `--no-sandbox`, `--disable-gpu-sandbox`, TLS
  bypass, Python webview server, or listener on port 5176. Renderer command
  lines contain `--enable-sandbox`.
- The official 2048×2048 icon matched the recorded source hash and the product
  metadata remains visibly labeled unofficial.

## Real KDE Wayland runtime

- The clean build and immutable installed release both launched in packaged
  mode on `--ozone-platform=wayland` with GPU compositing enabled.
- KWin supplied the standard titlebar, shadows, scaling, and controls; no
  custom titlebar or X11 session was used.
- The `app://` renderer mounted the full unified application: New task,
  Scheduled, Plugins, Sites, Chat, project/task surfaces, local permissions,
  and browser-use. App-server `0.144.1` completed its initialize handshake.
- A renderer-layout deduplication experiment produced only the upstream
  “Something went wrong” fallback. It was rejected before installation. Exact
  testing proved `26.707` currently resolves assets from both embedded and
  staged layouts, so both are retained while the Python/localhost server is
  removed.
- A second launch delivered `--new-chat` through the Unix handoff socket in 91
  ms and did not create another main application process.
- `--safe-mode` remained on native Wayland and added GPU-disable recovery
  switches rather than requiring X11.
- Interrupting the launcher initially revealed an orphaned Electron tree. The
  exit trap now sends TERM, waits three seconds, escalates if necessary, and
  reaps identified runtime children. The repeated timeout test left zero Work
  or app-server processes.

## Performance observations

- Final build footprint: approximately 929 MiB. It is ~84 MiB smaller than the
  initial working candidate after pruning Node headers, npm, Corepack, manuals,
  and build documentation. The staged/embedded renderer duplication accounts
  for roughly 189 MiB and remains a tracked resolver task.
- Visible primary-window `ready-to-show` occurred about 0.5–0.6 seconds after
  Electron startup on a warm cache; launcher preparation was about 0.3–0.8
  seconds after initial plugin staging.
- A broad prompt-capability disable suppressed primary startup and was rejected.
  The final narrow patch keeps prompt/Quick Chat available while removing only
  their startup-prewarm call. Settled startup now has one renderer instead of
  primary + three hidden renderers; no hotkey-window lifecycle appeared until
  explicitly requested.
- During primary-runtime selection the Electron main process reached roughly
  1.3 GiB RSS and the full tree exceeded the old WebKit shell budget. This is
  substantially heavier than `chatgpt-desktop-linux` and cannot honestly be
  described as a 768 MiB product today.
- A two-core, 768 MiB, no-swap safe-mode scope survived for 20 seconds without
  an OOM or profile corruption but did not reach a usable signed-out window
  before the test timeout. The scope exposed and validated the child cleanup
  fix. Low-memory acceptance therefore remains open rather than falsely
  claimed.

## Installation

- The installed release path is content addressed under
  `~/.local/opt/chatgpt-work-linux/versions/`; `current` identifies the active
  checksum and `previous` is retained after upgrades.
- Every file is covered by `.codex-linux/SHA256SUMS`; verification passed before
  publication and again from the immutable release.
- `current` was switched atomically and `~/.local/bin/chatgpt-work-linux`
  resolves through it. Desktop and AppStream files validate successfully.
- `chatgpt-work-linux doctor --json` reports Electron 42.1.0, native Wayland,
  Codex CLI availability, sandbox enabled, `app://` origin, and isolated XDG
  profile state.
- `chatgpt-desktop-linux` was not changed and remains the separate lightweight
  public-web application.

## Remaining interactive matrix

The unified signed-in home, app-server, Plugins/Sites, browser-use availability,
single instance, safe mode, and shutdown paths were exercised. A release still
needs deliberate user-visible QA for Google/email sign-in from a fresh profile,
file upload/download, an external URL, microphone/camera, screen share,
AppShots cancellation/success, offline recovery, and permission deny/allow.
There is no X11 session on the target machine, so an X11 compatibility lane was
not claimed.
