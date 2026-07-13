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
  - Linux Computer Use UI and capability gates required
  - final renderer Computer Use platform predicate verified byte-for-byte
  - portal-only Wayland input with last-moment target-focus verification
  - XDG profile isolation and bounded diagnostics
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
Electron executable, and uses an isolated XDG data root. Static renderer files
load through Electron's registered `app://` scheme. There is no TCP asset
server, development URL, unattended dependency update, or native-module
compilation. If no compatible Codex CLI is installed, the adapter retains its
explicit user-confirmed CLI installation prompt.

Electron runs on Wayland with standard compositor decorations. Renderer
processes must report `--enable-sandbox`; the build and smoke test reject
`--no-sandbox` and `--disable-gpu-sandbox`. The app-server protocol is exposed
only to the packaged local application plane. Ordinary remote web content does
not receive native IPC or shell access.

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

Logs are bounded and operational diagnostics go to stderr/journald. Updates
are explicit build/install transactions—there is no polling updater.

## Upstream observation

The inspector never executes the macOS binaries. It records DMG integrity,
bundle metadata, Mach-O headers, ASAR/plugin inventories, privacy keys, and
component hashes. The Linux build uses only the portable application plane and
Linux-rebuilt modules; Apple-only executables are not launched.
