# Flatpak sandbox audit

## Runtime boundary

The Flatpak app ID is `io.github.chatgpt_work_linux`, matching the default
`GApplication` identity, exported desktop file, icon, and AppStream component.
It targets GNOME Platform/SDK 50 and the Freedesktop 25.08 stable Rust SDK
extension. Cargo dependencies are generated from `Cargo.lock`, downloaded by
Flatpak Builder with recorded crate SHA-256 values, and consumed by Cargo with
`--frozen` and no build-time network.

`cargo-sources.json` was generated with the official
`flatpak/flatpak-builder-tools` generator at commit
`737c0085912f9f7dabf9341d4608e2a77a51a73a`. Regeneration is explicit through
`scripts/update-flatpak-sources.sh`; the script requires a reviewed generator
path and publishes validated JSON atomically instead of fetching a mutable tool
during the build.

The manifest grants only:

| Grant | Reason |
|---|---|
| `--share=network` | Reach the public HTTPS ChatGPT service. |
| `--share=ipc` | Required for efficient WebKit shared-memory rendering. |
| `--socket=wayland` | Primary KDE/Wayland display path. |
| `--socket=fallback-x11` | Compatibility only when Wayland is unavailable. |
| `--socket=pulseaudio` | Voice/media playback and capture after WebKit permission consent. |
| `--device=dri` | Sandboxed GPU acceleration; safe mode can disable it. |
| `--filesystem=xdg-download` | Save user-approved WebKit downloads in the standard download directory. |

It deliberately has no `home` or `host` filesystem access, no arbitrary X11
socket, no session/system bus ownership, no broad D-Bus talk names, no device
access beyond DRI, no host command execution, no SSH agent, and no background
permission. File upload uses the desktop file chooser/document portal;
screenshots and global shortcuts use their dedicated portals.

## Engine behavior

The sandbox ships only the system WebKitGTK runtime. It does not bundle a
browser and cannot launch a host Chromium app profile without the intentionally
forbidden host-spawn permission. Its desktop actions therefore offer WebKit,
safe mode, companion mode, and the default browser—not a misleading Chromium
action.

Google OAuth remains subject to Google's embedded-user-agent restriction. In a
native Arch/user install the whole profile can move to an isolated installed
Chromium app window. In Flatpak that handoff is unavailable by design; email
sign-in or the default browser is the honest fallback. Cookie copying and host
browser profile access remain prohibited.

## Update and persistence model

Flatpak owns immutable application/runtime updates and rollback. Profile data
is confined to Flatpak's XDG app directory, while selected documents are
mediated by portals and downloads are limited to `xdg-download`. The
application still has no polling updater or append-only log.

## Validation gates

- `flatpak-builder --show-manifest` must parse the manifest.
- Both native and Flatpak desktop entries and the AppStream component must
  validate.
- A full offline/frozen Flatpak build must complete from generated crate
  sources.
- `flatpak info --show-permissions` must match the grant table above.
- `doctor --json`, Wayland launch, portal screenshot/global-shortcut behavior,
  and uninstall-with-profile-preservation must be checked from the installed
  Flatpak.
