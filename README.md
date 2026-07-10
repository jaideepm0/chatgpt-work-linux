# chatgpt-work-linux

`chatgpt-work-linux` is a community Linux compatibility build for the unified
ChatGPT Work/Codex desktop application. The project is transitioning from its
completed Rust/WebKit public-web baseline to the portable Electron application
plane observed in ChatGPT `26.707.31428`. The preserved public-web client is
installed independently as `chatgpt-desktop-linux`.

This project is not an OpenAI product and is not endorsed or supported by
OpenAI. It does not redistribute the official macOS application or use a
private ChatGPT API. The desktop entry uses the unmodified official ChatGPT app
icon for service identification; OpenAI owns that icon and the “ChatGPT” and
“ChatGPT Work” marks. The application, desktop entry, About dialog, and package
metadata identify this build as unofficial.

## What is implemented

- Wayland-first native Rust/GTK shell with one shared WebKit context and no Node, Electron,
  Python, or local HTTP server in the runtime path.
- Persistent, isolated XDG profiles and an ephemeral `--private` profile.
- Strict HTTPS navigation policy: first-party/authentication pages stay inside;
  unrelated links open in the system browser; unsafe schemes are blocked.
- Standard compositor titlebar, native application menu/actions, settings, and
  per-request microphone, camera, screen, location, notification, and
  cross-site sign-in-storage decisions.
- Portal global shortcut, compact always-on-top companion layout, and portal
  screenshots copied to the clipboard for pasting into the message composer.
- Native download handling with sanitized, collision-safe filenames.
- Bounded web-process crash recovery, unresponsive/offline feedback, safe mode,
  and Chromium/browser fallbacks.
- Structured `doctor`, path, effective-config, cache cleanup, and upstream-DMG
  inspection commands.
- Atomic user-local installs that retain the previous version, plus a native
  Arch package builder.

The default desktop shortcut is `Ctrl+Alt+Space`; the desktop portal asks the
user to approve or change it. On desktops without the Global Shortcuts portal,
bind `chatgpt-work-linux --toggle` in the desktop's shortcut settings.

## Upstream architecture change

The newly supplied official artifact is ChatGPT `26.707.31428` (bundle `5059`),
a unified Electron 42 application with a portable ASAR, local app-server,
plugins, skills, browser-use resources, and Work renderer assets. Its exact
SHA-256 is
`6f67af7e2f934093ab8afebcec11374d40c8db8f9100fb6620f24155401d8319`.
The structural inventory is recorded in
[docs/upstream-snapshot.json](docs/upstream-snapshot.json), and the architecture
pivot and compatibility gates are documented in
[docs/unified-electron-assessment.md](docs/unified-electron-assessment.md).

OpenAI's [desktop page](https://chatgpt.com/features/desktop/) offers macOS and
Windows builds and says the macOS build requires macOS 14+ on Apple Silicon.
Its [download page](https://chatgpt.com/download/) describes the unified desktop
experience as containing ChatGPT Work and Codex. This implementation uses the
public web surface as the remote product plane while a native Rust controller
supplies Linux lifecycle, policy, portals, settings, recovery, and packaging.
It does not translate or patch proprietary application code.

The current local DMG is 561,015,842 bytes and is byte-identical to the current
artifact named `Codex.dmg` in the sibling reference checkout. The older 78 MiB
Swift artifact and the initial web-shell assessment remain useful historical
evidence, but no longer describe the current Work release.

## Requirements

Runtime:

- Linux x86_64 (the Rust code is portable to aarch64; package output is not yet
  published for it)
- GTK 3.24+
- WebKitGTK 4.1 (WebKitGTK 2.40+)
- XDG Desktop Portal; the desktop-specific backend is recommended
- PipeWire/GStreamer media plugins for screen sharing and voice

Arch Linux packages:

```bash
sudo pacman -S --needed gtk3 webkit2gtk-4.1 xdg-desktop-portal cargo-cyclonedx jq
```

Build requirements are Rust/Cargo, `pkg-config`, and the package-managed
`cargo-cyclonedx` and `jq` tools for release SBOM generation. Python and 7-Zip
are used only by the optional upstream metadata inspector, never to launch the
app.

## Build, run, and install

```bash
make check
make build
make sbom
make smoke-wayland
make run
make install-user
```

The atomic user install lives under
`~/.local/opt/chatgpt-work-linux`, creates
`~/.local/bin/chatgpt-work-linux`, installs desktop metadata, and preserves the
previous binary for rollback.

Build an Arch package:

```bash
make package-pacman
sudo pacman -U dist/chatgpt-work-linux-*.pkg.tar.zst
```

`make smoke-wayland` runs an isolated private profile with no X11 display,
forces the GTK Wayland backend, verifies the profile-scoped single instance and
both WebKit subprocesses, exercises hide/show handoff, checks shutdown cleanup,
and enforces the two-core-class 768 MiB cgroup memory ceiling.

`make sbom` emits a reproducible CycloneDX 1.5 JSON inventory in `dist/`.
Native packages include the same all-dependency inventory alongside the
architecture and upstream-provenance documents.

Build a least-privilege Flatpak after installing GNOME SDK 50 and the stable
Rust 25.08 SDK extension:

```bash
make package-flatpak
flatpak install --user --reinstall --bundle dist/chatgpt-work-linux-*.flatpak
```

The [Flatpak sandbox audit](docs/flatpak-sandbox.md) documents every grant and
the stricter authentication tradeoff. The native Arch/user package remains the
full compatibility target because Flatpak intentionally cannot spawn or read a
host Chromium profile.

## Usage

```bash
chatgpt-work-linux
chatgpt-work-linux --companion
chatgpt-work-linux --toggle
chatgpt-work-linux --safe-mode
chatgpt-work-linux --engine chromium
chatgpt-work-linux --engine browser
chatgpt-work-linux --profile team
chatgpt-work-linux --private
chatgpt-work-linux doctor --json
chatgpt-work-linux paths
chatgpt-work-linux print-config
chatgpt-work-linux clear-cache --yes
```

Copy [config.example.toml](config.example.toml) to the config path printed by
`chatgpt-work-linux paths`. Profiles have separate cookies, storage, cache, and
single-instance identities.

The default `auto` engine begins with system WebKitGTK. If Google sign-in is
chosen, the app explains Google’s embedded-browser restriction and can move the
whole profile to an isolated installed-Chromium app window. It remembers that
choice, does not copy or decrypt cookies, and never disables browser security.

## Refresh or inspect the official reference artifact

This is a research/provenance operation, not part of a normal build:

```bash
./scripts/fetch-upstream.sh --output ./ChatGPT.dmg \
  --metadata ./docs/upstream-snapshot.next.json
./scripts/fetch-upstream.sh --offline --output ./ChatGPT.dmg
chatgpt-work-linux inspect-upstream ./ChatGPT.dmg
```

The downloader is restricted to the official HTTPS URL, uses bounded retries
and an atomic partial file, records response metadata, validates the DMG, and
never executes it. The mutable official URL does not publish a SHA-256, so each
retrieval is captured as a new observation rather than silently trusted.

## Documentation

- [Reference audit and improvement plan](docs/audit-and-improvement-plan.md)
- [Complete codex-desktop-linux review](docs/codex-desktop-linux-review.md)
- [Architecture, security, and performance design](docs/architecture.md)
- [Current upstream snapshot](docs/upstream-snapshot.json)
- [ChatGPT Work upstream assessment](docs/work-upstream-assessment.md)
- [Unified Electron artifact and architecture assessment](docs/unified-electron-assessment.md)
- [Current validation evidence](docs/validation-report.md)
- [Flatpak sandbox audit](docs/flatpak-sandbox.md)
- [Security policy](SECURITY.md)

## Known limits

- This is not an official or supported Linux ChatGPT client. The web service
  can change independently of this shell.
- Google OAuth is intentionally not attempted in embedded WebKit. Accept the
  Chromium handoff or launch with `--engine chromium`; email sign-in can remain
  in WebKit.
- Apple-only integrations (Handoff, Apple Events, macOS Accessibility, native
  Calendar/Contacts/Reminders) are intentionally not imitated.
- “Work with Apps” context capture needs a separately reviewed, explicit IDE or
  AT-SPI integration with preview and approval. It is not implemented by
  scraping foreground applications.
