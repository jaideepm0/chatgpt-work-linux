# chatgpt-work-linux

`chatgpt-work-linux` is an unofficial, local Linux compatibility build of the
unified ChatGPT desktop application, including Chat, Work, Codex, plugins,
Sites, scheduled work, and the account-gated features present in OpenAI's
current desktop release.

It is not produced, supported, or endorsed by OpenAI. The official artifact,
application resources, ChatGPT name, and public icon remain OpenAI property.
This repository does not contain or redistribute the DMG, extracted app, or
the external compatibility adapter; users build locally from the official
download.

## What this build fixes

- Runs the actual packaged desktop renderer from `app://`; it is not a
  `chatgpt.com` web wrapper and has no localhost asset server.
- Uses Electron's native Wayland/Ozone path and standard compositor window
  decorations.
- Retains Chromium's renderer sandbox and rejects generated launchers that add
  `--no-sandbox` or `--disable-gpu-sandbox`.
- Gives Electron a packaged executable identity, so `app.isPackaged` is true
  and the application cannot regress to the development URL.
- Removes the unconditional startup Quick Chat prewarm that created a second
  blank window on Linux; Quick Chat remains available when requested.
- Requires the adapter's Linux Computer Use UI, install-flow, native-app
  discovery, and backend-gate patches; a skipped capability patch fails the
  build instead of rendering the plugin as unavailable.
- Routes Computer Use pointer and keyboard actions through the user-consented
  Wayland Remote Desktop portal. The build disables `ydotool` and direct
  `/dev/uinput` fallbacks on Wayland, and revalidates a targeted window after
  portal setup immediately before keyboard injection.
- Refuses to publish an artifact if the Computer Use executable, MCP manifest,
  plugin manifest, or backend self-check is missing, even when the external
  adapter reports only a warning.
- Keeps ChatGPT Work state in an isolated XDG profile, bounds launcher logs,
  validates native dependencies, and installs immutable releases atomically.

Remote HTTPS content does not receive a shell bridge. The privileged desktop
and computer-use paths remain the packaged application's validated local
surfaces, with the adapter's portal and Linux policy patches applied at build
time.

## Current verified upstream

| Field | Value |
|---|---|
| Official URL | `https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg` |
| ChatGPT version | `26.707.62119` (bundle `5211`) |
| Size | `615,738,501` bytes |
| SHA-256 | `c243c94f8de6a51f5530ffe1f8d0c1588733d890ac692e34aaca06d95ba637ca` |
| Electron | `42.1.0` |
| Adapter commit | `a8dbcb954f6108070b5633afef69792bf12f5507` |

The downloader rejects non-HTTPS redirects, unexpected hosts, artifacts at or
below 500 MiB, size drift, hash drift, and invalid DMGs. The complete observed
metadata is in [docs/upstream-snapshot.json](docs/upstream-snapshot.json).

## Requirements

- x86_64 Linux with a Wayland session and working user namespaces
- systemd user session, XDG Desktop Portal, PipeWire, and a desktop portal
  backend
- build tools required by the external `codex-desktop-linux` adapter
- `curl`, Python 3, Node.js, Rust/Cargo, 7-Zip, `desktop-file-utils`, and
  `appstreamcli`
- the reference checkout at `~/programs/codex-desktop-linux`, or set
  `CODEX_DESKTOP_LINUX_REPO`

The adapter checkout is fetched and archived into the XDG cache by exact Git
commit. It is never copied into this repository.

## Build, verify, and install

```bash
make check
make build
make doctor
make smoke-wayland
make install-user
```

`make build` downloads the allowlisted official artifact when necessary,
verifies it against the checked-in snapshot, and publishes a completed build
atomically at `.work/chatgpt-work-app`. `make install-user` publishes an
immutable release under `~/.local/opt/chatgpt-work-linux`, switches `current`
only after verification, and retains one previous release for rollback.

Launch or inspect it with:

```bash
chatgpt-work-linux
chatgpt-work-linux doctor --json
chatgpt-work-linux computer-use-doctor
```

`computer-use-doctor` checks the native Wayland portal, AT-SPI, window-targeting,
input, and MCP-tool backends without starting the UI. If the desktop needs a
one-time portal or accessibility setup, run the explicitly user-initiated
`chatgpt-work-linux computer-use-setup` command.

The desktop entry is `ChatGPT Work Linux (Unofficial)`. Uninstalling preserves
the profile unless purge is explicitly requested:

```bash
make uninstall-user
./scripts/uninstall-user.sh --purge
```

## Updating upstream

```bash
make refresh-upstream
./scripts/refresh-upstream-snapshot.sh --check
```

Review snapshot and adapter drift before committing a new version. Required
patch misses are fatal, including every Computer Use capability patch;
optional misses remain visible in the patch report.
Build reports are stored under `.work/reports/<version>/` and are ignored by
Git.

## Documentation

- [Architecture and trust boundaries](docs/architecture.md)
- [Upstream feature audit](docs/upstream-feature-audit.md)
- [Artifact assessment](docs/work-upstream-assessment.md)
- [Adapter review](docs/codex-desktop-linux-review.md)
- [Validation evidence](docs/validation-report.md)
- [Current snapshot](docs/upstream-snapshot.json)

## Known limits

- Feature availability depends on account entitlements and server flags.
- The official macOS executable and Apple-only helpers are not run on Linux;
  the portable application plane is hosted by a verified Linux Electron and
  rebuilt Linux native modules.
- This is a local compatibility build. Do not redistribute the generated app
  or the proprietary upstream artifact.
