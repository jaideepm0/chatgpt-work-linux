# chatgpt-work-linux

`chatgpt-work-linux` is an unofficial community compatibility build of the
unified ChatGPT Work/Codex desktop application for Linux. It runs the real
portable application plane observed in ChatGPT `26.707.31428`: local
app-server, projects, tasks, plugins, Sites, scheduled work, browser-use,
document tools, and the unified Work renderer. It is not a `chatgpt.com` web
wrapper.

This is not an OpenAI product and is not endorsed or supported by OpenAI. The
project does not publish the official DMG or a rebuilt proprietary binary;
users build locally from their own artifact. OpenAI owns the ChatGPT name,
marks, application resources, and icon. The desktop entry and product metadata
keep this build visibly labeled “Unofficial.”

The lightweight public-web client remains a separate installed application,
`chatgpt-desktop-linux`. The former Rust/WebKit implementation of this repo is
preserved at tag `rust-webkit-baseline-v0.1.0`.

## Current input and provenance

The reviewed local input is `ChatGPT-work.dmg`:

- ChatGPT version `26.707.31428`, bundle `5059`
- Electron `42.1.0` / Chromium 150
- size `561,015,842` bytes
- SHA-256 `6f67af7e2f934093ab8afebcec11374d40c8db8f9100fb6620f24155401d8319`

The build fails closed if that hash or any required compatibility invariant
does not match. [The artifact assessment](docs/unified-electron-assessment.md)
and [machine-readable snapshot](docs/upstream-snapshot.json) record the audit.
No Mach-O executable is run.

The icon at `assets/chatgpt-work-linux.png` is the exact 2048×2048 ChatGPT icon
from the supplied artifact. Its hash and trademark disclaimer are recorded in
[ICON-PROVENANCE.md](assets/ICON-PROVENANCE.md).

## Architecture and safeguards

- Native Wayland/Ozone is selected automatically on KDE Wayland; X11 is not
  required. KWin supplies the standard titlebar and window controls.
- Electron identifies as packaged and uses its privileged, secure `app://`
  renderer. There is no Python server, localhost port, or duplicated extracted
  webview in the installed runtime.
- Chromium renderer and GPU sandboxes stay enabled. The launcher never adds
  `--no-sandbox` or disables TLS/web security.
- ChatGPT Work owns isolated XDG profile, browser, cache, and state paths. An
  inherited `CODEX_HOME` from another app is deliberately ignored; advanced
  users may explicitly set `CHATGPT_WORK_CODEX_HOME`.
- Single-instance ownership is acquired before cache/plugin mutations or
  app-server startup. Repeated launches hand off to the running process.
- Hidden Quick Chat/prompt windows are lazy by default, updater polling is
  disabled, diagnostics go to stderr/journald, and file logging is bounded and
  opt-in with `CODEX_LINUX_FILE_LOG=1`.
- Production builds contain a pinned Node runtime but remove build headers,
  npm, Corepack, and the duplicate webview after native modules are built.
- User installation is immutable and atomic, retains one rollback release,
  and preserves profiles unless uninstall is given `--purge`.

Remote web content does not receive an additional Linux shell bridge. Native
actions remain in the audited Electron main process, with Linux portal and
sender checks supplied by the compatibility engine.

## Build and install

The repository expects the user-supplied file at `./ChatGPT-work.dmg`.

Build dependencies include Bash, Node.js, Python 3, curl, unzip, tar, a modern
7-Zip with APFS support, make, g++, and the native libraries required by
Electron modules. The application also needs the current Codex CLI for its
initial local app-server:

```bash
npm install -g @openai/codex
```

Then run:

```bash
make check
make build
./.work/chatgpt-work-app/start.sh doctor --json
make install-user
chatgpt-work-linux doctor --json
chatgpt-work-linux
```

The verified build is published at `.work/chatgpt-work-app`. The user install
lives under `~/.local/opt/chatgpt-work-linux`, with an atomic launcher at
`~/.local/bin/chatgpt-work-linux` and desktop metadata under `~/.local/share`.

Useful recovery and launch modes:

```bash
chatgpt-work-linux --new-chat
chatgpt-work-linux --quick-chat
chatgpt-work-linux --safe-mode
chatgpt-work-linux --wayland
chatgpt-work-linux --disable-gpu
CODEX_LINUX_FILE_LOG=1 chatgpt-work-linux
```

`--safe-mode` keeps Wayland when the session is Wayland and disables GPU
acceleration. `--x11` is an explicit troubleshooting fallback only.

Uninstall while preserving profiles:

```bash
make uninstall-user
```

Remove profiles as well:

```bash
./scripts/uninstall-user.sh --purge
```

## Validation

`make check` validates the preserved Rust baseline and upstream tooling, all
compatibility patch fixtures, shell syntax, desktop metadata, and AppStream
metadata. `make build` additionally verifies the exact DMG, enforces every
required patch, compiles native Electron 42 modules, checks shared libraries,
confirms the official icon, rejects sandbox-disable switches, and writes a
complete installed-file checksum manifest.

Runtime acceptance covers native Wayland startup, packaged `app://` loading,
single-instance handoff, safe mode, app-server handshake, sign-in persistence,
renderer sandboxing, clean shutdown, idle process/memory measurements, and a
two-core/768 MiB constrained lane. Some opt-in Work capabilities download a
large signed Linux primary runtime; their first-run peak is tracked separately
from the base shell.

## Documentation

- [Architecture and security assessment](docs/unified-electron-assessment.md)
- [Audit and improvement roadmap](docs/audit-and-improvement-plan.md)
- [Current validation report](docs/validation-report.md)
- [Complete codex-desktop-linux review](docs/codex-desktop-linux-review.md)
- [Upstream snapshot](docs/upstream-snapshot.json)
- [Security policy](SECURITY.md)

OpenAI’s public [ChatGPT release notes](https://help.openai.com/en/articles/6825453-chatgpt-release-notes)
describe AppShots, goal mode, browser improvements, and remote control. Its
[Codex app announcement](https://openai.com/index/introducing-the-codex-app/)
describes the multi-agent desktop command center that this local Linux
compatibility build targets.

## Known limits

- This exact build supports Linux x86-64. It deliberately avoids
  `target-cpu=native` and AVX-only output for older systems.
- Apple-only Handoff, Apple Events, macOS Accessibility, and native Apple app
  integrations are not imitated.
- Account flags and service entitlements still control feature availability.
- A newly isolated profile may perform a large one-time download of OpenAI’s
  Linux primary runtime when an advanced Work feature first needs it.
