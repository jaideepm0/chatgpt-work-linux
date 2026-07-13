# chatgpt-work-linux

`chatgpt-work-linux` is an unofficial community Linux desktop client for the
public ChatGPT service, including server-delivered Work features available to
the signed-in account. The default runtime is a native Rust/GTK/WebKitGTK
application; installed Chromium and the system browser are compatibility
fallbacks.

This is not an OpenAI product and is not endorsed or supported by OpenAI. It
does not redistribute, patch, translate, or execute the official macOS
application and does not use a private ChatGPT API. OpenAI owns the ChatGPT
name, marks, and unmodified public application icon used for desktop
identification. Application and package metadata visibly say “Unofficial.”

## Implemented

- Wayland-first Rust/GTK shell with one shared WebKit context and no Electron,
  Node, Python, bundled browser, or local HTTP server in the default runtime.
- Persistent isolated XDG profiles and an ephemeral `--private` profile.
- Strict navigation policy: trusted ChatGPT/authentication pages stay inside,
  unrelated HTTPS links open externally, and unsafe schemes are blocked.
- Native settings for engine, performance, privacy, global shortcut, and
  background behavior, saved atomically with mode 0600.
- Per-request microphone, camera, screen, location, notification, and
  cross-site sign-in-storage decisions with trusted-sender checks.
- Portal global shortcut and user-initiated Screenshot flow; screenshots are
  copied to the clipboard for an explicit paste into the composer.
- Native upload chooser, sanitized collision-safe downloads, bounded recovery,
  safe mode, Chromium/browser fallbacks, and structured diagnostics.
- Atomic user-local install with one rollback version, Arch packaging, Flatpak,
  SBOM output, and profile-preserving uninstall.

General control of other desktop applications is intentionally not exposed to
remote web content. The current unified upstream artifact does contain a
bundled Computer Use service, but importing its privileged bridge would violate
this client's trust boundary. The evidence and a safe staged strategy are in
[the upstream feature audit](docs/upstream-feature-audit.md).

## Why the macOS binary is reference-only

The current official ChatGPT `26.707.62119` artifact is a 615 MB unified
Chat/Work/Codex Electron application for ARM64 macOS. It contains `app.asar`,
bundled plugins, and Apple-only helpers. Repository policy treats that artifact
as reference input: its proprietary application plane is not executed,
translated, patched, or included in Linux packages.

The bounded inspector records archive integrity, public bundle metadata,
Mach-O headers, exact resource-bundle names, privacy-category keys, and hashes.
It never executes the app or extracts proprietary UI. The observed artifact is
615,738,501 bytes with SHA-256
`c243c94f8de6a51f5530ffe1f8d0c1588733d890ac692e34aaca06d95ba637ca`.

## Requirements

Runtime:

- Linux x86_64 (the Rust source is portable to aarch64)
- GTK 3.24 and WebKitGTK 4.1 / WebKitGTK 2.40+
- XDG Desktop Portal and the desktop-specific backend
- PipeWire/GStreamer media plugins for screen sharing and voice

Build requirements are Rust/Cargo and `pkg-config`. Python 3, 7-Zip, and curl
are used only by the optional upstream reference inspector.

On Arch Linux:

```bash
sudo pacman -S --needed gtk3 webkit2gtk-4.1 xdg-desktop-portal cargo-cyclonedx jq
```

## Build, validate, and run

```bash
make check
make build
./target/release/chatgpt-work-linux doctor --json
make run
```

Install or package:

```bash
make install-user
make package-pacman
make package-flatpak
make sbom
```

The user install lives under `~/.local/opt/chatgpt-work-linux`, exposes
`~/.local/bin/chatgpt-work-linux`, switches releases atomically, and retains
the previous release for rollback.

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

Copy [config.example.toml](config.example.toml) to the path printed by
`chatgpt-work-linux paths`. Profiles do not share cookies, storage, cache, or
single-instance ownership.

Auto mode begins with WebKitGTK. Google blocks OAuth in embedded user agents,
so the app can hand the whole isolated profile to an installed Chromium app
window. It does not copy or decrypt cookies and never disables browser
security.

## Refresh the official reference snapshot

This is a developer provenance operation, not part of normal build or launch:

```bash
make refresh-upstream
./scripts/refresh-upstream-snapshot.sh --check
./scripts/refresh-upstream-snapshot.sh --offline
chatgpt-work-linux inspect-upstream ./ChatGPT.dmg
```

The downloader is restricted to the compiled official HTTPS URL, bounds size
and time, safely resumes matching partials, validates the DMG, writes the
proprietary artifact only to ignored paths, and atomically publishes metadata.

## Documentation

- [Upstream feature and Linux parity audit](docs/upstream-feature-audit.md)
- [ChatGPT Work artifact assessment](docs/work-upstream-assessment.md)
- [Architecture and security design](docs/architecture.md)
- [Current upstream snapshot](docs/upstream-snapshot.json)
- [Reference codebase review](docs/codex-desktop-linux-review.md)
- [Improvement roadmap](docs/audit-and-improvement-plan.md)
- [Validation evidence](docs/validation-report.md)
- [Flatpak sandbox audit](docs/flatpak-sandbox.md)
- [Security policy](SECURITY.md)

## Known limits

- The service can change independently of this community shell, and account
  flags still control product availability.
- Google OAuth requires the Chromium/browser handoff; email sign-in can remain
  in WebKitGTK.
- Apple Events, Handoff, macOS Accessibility, and native Apple app integrations
  are not imitated.
- Local app context and input automation require a separate threat model,
  visible preview, per-action approval, and portal-scoped implementation. They
  are not implemented by scraping or injecting input into the desktop.
