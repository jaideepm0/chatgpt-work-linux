# Validation report

Date: 2026-07-10

Host: Arch Linux x86_64, KDE Plasma/KWin Wayland

## Native runtime

- `make check` passed formatting, Clippy with warnings denied, 24 Rust tests,
  adversarial upstream-tool tests, shell syntax, desktop-file validation, and
  pedantic AppStream validation.
- The real host session reported `XDG_SESSION_TYPE=wayland`,
  `WAYLAND_DISPLAY=wayland-0`, KDE, GTK 3.24.52, and WebKitGTK 2.52.4.
- A real KWin-rendered run showed standard compositor decorations, the native
  File/View/Tools/Help menu, a 1180-pixel main window, and a 480×720 companion
  window. No custom titlebar was used.
- A second invocation forwarded to the existing profile instance in 73 ms and
  created the companion window without a second controller process. Exported
  GApplication actions included focus, navigation, reload, new window,
  companion, screenshot, settings, diagnostics, Chromium handoff, About, and
  quit.
- The native quit action saved mode-0600 geometry state, stopped the controller
  and all WebKit child processes, and left no profile helper running.
- With the session D-Bus address removed, the Wayland window still launched in
  non-unique fallback mode; a concurrent process failed closed on the profile
  advisory lock instead of sharing browser state.

## Compatibility and authentication

- The ChatGPT service page loaded in WebKit on native Wayland.
- Google authorization navigation produced the explicit installed-Chromium
  handoff. Accepting it persisted the engine choice without reading or copying
  WebKit cookies.
- Real-host testing found that retaining a hidden WebKit controller during the
  handoff doubled renderer memory. The lifecycle was changed so persistent
  handoffs exit WebKit immediately. Private sessions instead explain the
  explicit `--engine chromium --private` relaunch, which avoids either leaking
  a temporary profile or keeping two engines alive.
- Google credentials were not automated or captured. Final account consent is
  intentionally completed by the user in the normal Chromium UI.

## Older-hardware budget

A native Wayland test ran under a user cgroup with two CPU cores and
`MemoryMax=768M`. Auto performance selection enabled WebKit's supported 512 MiB
per-process memory-pressure setting. The page remained responsive, native
actions worked, and the unit exited successfully without an OOM or orphan.
Systemd recorded 1.614 seconds of CPU across 13.640 seconds wall time and a
768 MiB peak including WebKit's multi-process tree.

## Package and installation

- The Arch package was built from a deterministic checksummed source archive
  with Cargo `--frozen`; the build cache is keyed by that complete source hash.
- Package SHA-256:
  `a85c63c190e502dae9c81320258bf398b20b9eecc72cc140c316df0c7730652f`.
- Compressed size: approximately 1.7 MiB. Installed size: 3.90 MiB.
- The stripped PIE targets generic x86-64/Linux 4.4 and contains no detected
  workspace, Cargo-home, or Rustup-home path.
- The package contains the binary, desktop entry, scalable icon, AppStream
  metadata, license, configuration example, architecture, audit, and upstream
  provenance documents.
- `pacman -Qkk chatgpt-work-linux` reported 26 files and 0 altered files after
  installation.
- `/usr/bin/chatgpt-work-linux doctor --json` completed without a panic and
  reported a healthy Wayland runtime, both KDE portals, and installed Google
  Chrome and Microsoft Edge compatibility candidates.

## Flatpak roadmap target

- GNOME Platform/SDK 50 and the stable Rust 25.08 extension were installed from
  Flathub. Flatpak Builder fetched every locked crate by recorded SHA-256 and
  completed the application build with Cargo `--frozen`.
- AppStream composition succeeded and exported commit
  `23549e0dd0b7408f7c28619e611016e3615d0eedacfd432f2510ee9e4300792f`.
- The locally installable Flatpak bundle is approximately 1.3 MiB excluding
  the shared runtime.
- Installed permissions contain only `ipc`, `network`, Wayland,
  fallback-X11, PulseAudio, DRI, and `xdg-download`. There is no host/home
  filesystem, host spawn, broad bus, or input-device grant.
- Flatpak `doctor --json` reported a healthy GNOME 50 runtime on the KDE
  Wayland host, WebKitGTK 2.52.4, both portals, `flatpak_sandbox=true`, and no
  Chromium candidate inside the sandbox.
- A non-default Flatpak profile acquired its filtered D-Bus sub-name, loaded a
  real HTTPS page, forwarded a companion invocation in 99 ms, and exited
  cleanly through the exported native quit action.

## Remaining interactive release matrix

The production target has passed the native Wayland lifecycle and constrained
resource gates. File chooser upload, a real download, microphone/camera consent,
screen-share consent, screenshot cancellation/success, offline recovery, and a
complete user account sign-in still require user-visible interactions against
the live service and are tracked as the next release QA matrix rather than
claimed here without evidence.
