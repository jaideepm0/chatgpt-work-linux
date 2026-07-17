# Production architecture

## Decision

The production target is the real application plane from OpenAI's current
unified ChatGPT desktop release, adapted locally to a Linux Electron runtime.
The earlier Rust/GTK/WebKit public-web shell is retained only as historical
source and tooling; it is not built, installed, or packaged by the default
targets because it cannot provide the desktop Work product.

The DMG and extracted application are ignored local inputs. The compatibility
adapter is an external, commit-pinned checkout cached outside this repository.
Generated builds must remain visibly unofficial and must not be redistributed.

## Build flow

```text
allowlisted official ChatGPT.dmg (>500 MiB, exact size and SHA-256)
        |
        v
external adapter archived by exact clean Git commit
        |
        v
bounded extraction + deterministic required/optional patch report
        |
        v
Electron 42 Linux runtime + rebuilt native modules + app-server/plugins
        |
        v
repository hardening pass
  - packaged executable identity (app.isPackaged=true)
  - packaged app:// renderer; no localhost server
  - Chromium sandbox flags retained
  - Wayland-only Ozone default
  - startup blank-window prewarm removed
  - native tray resource + default-on close-to-tray lifecycle
  - warm-start socket handoff + single-instance reuse required
  - Chromium reduced-motion preference for bounded idle rendering
  - Linux Computer Use UI and capability gates required
  - final renderer Computer Use platform predicate verified byte-for-byte
  - portal-only Wayland input with last-moment target-focus verification
  - XDG Electron-profile isolation + canonical Codex task home
        |
        v
staged validation -> atomic build publication -> immutable user install
```

Every transformation has an exact-match invariant. A missing or ambiguous
required adapter patch, ASAR anchor, expected launcher anchor, native library,
artifact hash, or sandbox/origin assertion stops publication and leaves the
active install unchanged.

Computer Use is not enabled by merely staging an MCP binary. The build opts
into and requires the adapter's renderer availability, feature, install-flow,
native desktop-app discovery, and plugin-gate patches. The local backend then
selects AT-SPI, the compositor window backend, and an available user-consented
Wayland portal independently. A healthy backend with a missing UI patch is a
release failure.

On Wayland, pointer, literal-text, and keyboard actions use consented XDG
Remote Desktop portal sessions. The build applies an exact, drift-detecting
source patch to the external adapter: it disables uinput and `ydotool` on
Wayland, removes environment overrides that could bypass portal selection, and
rechecks targeted-window focus after portal setup immediately before input.
Targeted KDE text uses portal keysyms instead of preparing the clipboard before
the final focus check. No X11 input implementation or `/dev/uinput` permission
is required by the installed product.

## Runtime boundaries

The installed entry point is a small generated supervisor. It acquires the
adapter's instance/lifecycle controls, starts the packaged app-server and
Electron executable, and uses an isolated XDG root for Electron state. Local
Codex task, project, and CLI history stays in `$CODEX_HOME` (normally
`~/.codex`), matching the established Codex desktop and CLI boundary. A
disposable `CHATGPT_WORK_CODEX_HOME` override exists only for tests and
profiling. Static renderer files load through Electron's registered `app://`
scheme. There is no TCP asset server, development URL, unattended dependency
update, or native-module compilation. If no compatible Codex CLI is installed,
the adapter retains its explicit user-confirmed CLI installation prompt.

Electron runs on Wayland with standard compositor decorations. Renderer
processes must report `--enable-sandbox`; the build and smoke test reject
`--no-sandbox` and `--disable-gpu-sandbox`. The app-server protocol is exposed
only to the packaged local application plane. Ordinary remote web content does
not receive native IPC or shell access.

The system tray and warm start are lifecycle features, not additional
services. The tray uses the packaged `resources/icon-chatgpt.png` expected by
the current reviewed upstream main process and Electron's portable Linux tray
implementation. The official runtime's private
`Tray.whenReady()`/`Tray.isReady()` extensions
are optional; the stock API's synchronous constructor is treated as ready, as
documented by Electron. Electron itself chooses StatusNotifierItem first and
falls back to `GtkStatusIcon`, so production code contains no desktop-specific
tray backend. A second launch sends one bounded Unix-socket action to the
already running application and exits; it does not start another renderer or
app-server. The build keeps Quick Chat prewarming disabled, so enabling warm
start adds no hidden window or idle renderer. An absent tray or warm-start
setting means enabled in the reviewed packaged helper and launcher; explicit
user choices remain authoritative.

Tray portability follows Electron's public Linux contract
(`https://www.electronjs.org/docs/latest/api/tray/`) and the freedesktop
StatusNotifierItem protocol
(`https://specifications.freedesktop.org/status-notifier-item/latest/`).

The upstream application owns Chat, Work, Codex, authentication, plugins,
Sites, schedules, and feature settings. Linux patches own compositor behavior,
paths, portal integrations, process lifecycle, and platform capability
adaptation. Account and server flags still determine actual availability.

## Installation and recovery

User releases are content-addressed and immutable. Files and their manifest
are verified before `current` is switched; `previous` retains the last release.
Desktop metadata is published atomically. Failed fetch, build, patch,
validation, or install never removes the active release. Profiles are preserved
by default on uninstall.

The former compatibility-only XDG Codex home can be recovered with the explicit
history migration tool. It checks matching SQLx schemas, backs up the target
database under XDG state, copies only missing rollout files atomically, rewrites
their paths, merges rows in one SQLite transaction, and verifies the resulting
database. It never duplicates the established multi-gigabyte Codex store.

Logs are bounded and operational diagnostics go to stderr/journald. Updates
are explicit build/install transactions—there is no polling updater.

## Upstream observation

The inspector never executes the macOS binaries. It records DMG integrity,
bundle metadata, Mach-O headers, ASAR/plugin inventories, privacy keys, and
component hashes. The Linux build uses only the portable application plane and
Linux-rebuilt modules; Apple-only executables are not launched.
