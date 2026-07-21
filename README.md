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
- Makes the native unified-app system tray available with the exact production
  tray
  resource expected by the packaged main process. The portable Electron API
  is accepted when the official runtime's private tray-readiness extensions are absent;
  Electron selects StatusNotifierItem or its standard Linux fallback.
  Close-to-tray is explicit opt-in so a fresh profile does not retain the
  resource-heavy process tree after its last window closes; explicit Quit
  still drains the app normally.
- Supports opt-in warm-start IPC: subsequent launches focus or navigate the
  existing single instance instead of creating another Electron/app-server
  process tree. This is process reuse, not background prewarming.
- Requests Chromium's standard reduced-motion mode by default. This removes a
  persistent virtual-Wayland renderer animation load without patching styles;
  users who prefer full motion can add `--force-prefers-no-reduced-motion` to
  the generated `electron-flags.conf` file.
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
- Keeps Electron state in an isolated XDG profile while using the canonical
  Codex home for local tasks and project history, bounds launcher logs,
  validates native dependencies, and installs immutable releases atomically.

Remote HTTPS content does not receive a shell bridge. The privileged desktop
and computer-use paths remain the packaged application's validated local
surfaces, with the adapter's portal and Linux policy patches applied at build
time.

## Current verified upstream

| Field | Value |
|---|---|
| Official URL | `https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg` |
| ChatGPT version | `26.715.21425` (bundle `5488`) |
| Size | `618,657,103` bytes (590 MiB) |
| SHA-256 | `ff459150991612007549270d2d28c5e78cec6bd6ac200a7ada5ed6c031369b87` |
| Electron | `42.3.0` |
| Adapter commit | `b24e5ff2cfabbd1a366f711229b3b115aa4397fe` |

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

`make build` downloads the allowlisted official artifact when necessary into a
content-addressed cache as `ChatGPT.dmg`, verifies it against the checked-in
snapshot, and publishes a completed build atomically at
`.work/chatgpt-work-app`. `make install-user` publishes an
immutable release under `~/.local/opt/chatgpt-work-linux`, switches `current`
only after verification, and retains one previous release for rollback. Tray
and warm start require explicit opt-in; an absent setting remains disabled.

The first normal user install transactionally copies an existing
`~/.config/Codex` Electron identity into the required isolated profile, while
excluding disposable Chromium caches. It never replaces a non-empty target
silently. Existing installations that already split the profiles can recover
the signed-in identity with `make migrate-electron-profile`; if both profiles
contain data, review them and run
`scripts/migrate-electron-profile.sh --replace-target`. The displaced target is
kept under XDG state as a timestamped backup.

The app and Codex CLI intentionally share `$CODEX_HOME` (normally `~/.codex`),
so local Codex tasks and project threads remain visible on both surfaces. If a
previous compatibility build wrote sessions to its short-lived isolated home,
recover them once with `make migrate-codex-history`; the command backs up and
transactionally merges only non-conflicting threads.

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
make check-update
make refresh-upstream
# Review the candidate snapshot, DMG provenance, adapter drift, and patch report.
make validate-upstream-candidate
./scripts/refresh-upstream-snapshot.sh --promote \
  --expected-version VERSION \
  --expected-sha256 SHA256
make update-user
```

Refresh never changes the reviewed snapshot or reviewed artifact cache. It
stores an isolated candidate. Promotion is an offline second phase requiring
the exact reviewed version and SHA-256 plus successful isolated build, doctor,
Wayland smoke, and both runtime-profile receipts. It rejects downgrades unless
separately authorized and publishes the DMG under its digest before switching
the snapshot. `make update-user` consumes only that reviewed snapshot; it never
promotes upstream
metadata.

Review snapshot and adapter drift before promoting and committing a new version. Required
patch misses are fatal, including every Computer Use capability patch;
optional misses remain visible in the patch report. Tray creation,
close-to-tray quit handling, settings persistence, single-instance locking,
and warm-start launch actions are mandatory too.
Build reports are stored under `.work/reports/<version>/` and are ignored by
Git.

The user install can be swapped back to its verified previous release with
`make rollback-user`. Immutable upstream caches are retained for recovery;
inspect a bounded cleanup with `make prune-upstream-cache` and apply it only via
`scripts/prune-upstream-cache.sh --keep 2 --apply`.

See [Update security and release workflow](docs/update-security.md) for the
transaction boundaries, threat model, recovery rules, and release checklist.

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
