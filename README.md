# chatgpt-work-linux

`chatgpt-work-linux` is a lightweight community Linux desktop shell for the
official ChatGPT web experience, including ChatGPT Work where the signed-in
account has access. It uses the system WebKitGTK runtime by default and keeps
Chromium app mode and the system browser as compatibility fallbacks.

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

## Why the macOS binary is not converted

The official download currently serves the Work-capable ChatGPT `1.2026.183`
(build `1783607847`, commit `3dab2ed0d5`), an Apple Silicon-only native
Swift/AppKit/SwiftUI application. It has no Electron
runtime, `app.asar`, or portable web bundle, so the ASAR-rehosting strategy in
`codex-desktop-linux` does not apply. The exact inspected artifact and its
provenance are recorded in [docs/upstream-snapshot.json](docs/upstream-snapshot.json).

OpenAI's [desktop page](https://chatgpt.com/features/desktop/) offers macOS and
Windows builds and says the macOS build requires macOS 14+ on Apple Silicon.
Its [download page](https://chatgpt.com/download/) describes the unified desktop
experience as containing ChatGPT Work and Codex. This implementation uses the
public web surface as the remote product plane while a native Rust controller
supplies Linux lifecycle, policy, portals, settings, recovery, and packaging.
It does not translate or patch proprietary application code.

The current official DMG is 78,575,566 bytes compressed and 203,461,632 bytes
expanded. The 500+ MiB artifact seen beside this repository is the separate
Codex DMG, not a ChatGPT Work download. The structural Work assessment and
observed native feature bundles are recorded in
[docs/work-upstream-assessment.md](docs/work-upstream-assessment.md).

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
sudo pacman -S --needed gtk3 webkit2gtk-4.1 xdg-desktop-portal
```

Build requirements are Rust/Cargo and `pkg-config`. Python and 7-Zip are used
only by the optional upstream metadata inspector, never to launch the app.

## Build, run, and install

```bash
make check
make build
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
