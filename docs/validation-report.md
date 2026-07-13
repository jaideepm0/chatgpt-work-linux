# Validation report

Date: 2026-07-13

Host: Arch Linux x86_64, KDE Plasma/KWin, Wayland

## Native build and tests

- `make check` passed Rustfmt, Clippy with warnings denied, 24 Rust unit tests,
  deterministic/adversarial upstream-tool tests, shell syntax, both desktop
  files, pedantic AppStream validation, and Flatpak manifest expansion.
- `make build` produced the release Rust binary with remapped build paths and
  no `target-cpu=native` setting.
- `target/release/chatgpt-work-linux doctor --json` reported healthy with GTK
  3.24.52, WebKitGTK 2.52.5, KDE Wayland, Screenshot and Global Shortcuts
  portals, and installed Chrome/Edge compatibility candidates.
- `make smoke-wayland` passed isolated native-Wayland launch,
  profile-scoped single-instance/toggle handoff, WebKit child discovery, clean
  shutdown, and the constrained memory lane. Hide/show handoff took 54/61 ms;
  memory current/peak was 207,855,616/221,888,512 bytes.

## Upstream reference tooling

- The allowlisted downloader followed the current ChatGPT download page to the
  unified endpoint and verified the ignored 615,738,501-byte DMG with SHA-256
  `c243c94f8de6a51f5530ffe1f8d0c1588733d890ac692e34aaca06d95ba637ca`.
- Inspection classified ChatGPT `26.707.62119` as an ARM64 macOS Electron app
  and recorded 10,777 entries, eight bundled plugin families, six privacy
  usage categories, and 11 embedded application/XPC components. No artifact
  executable was run.
- `scripts/refresh-upstream-snapshot.sh --offline --check` passed against the
  checked-in schema-3 snapshot.

## Package and user-install checks

- `make package-pacman` completed a clean frozen source build, repeated all 24
  Rust tests, generated the SBOM, and produced
  `dist/chatgpt-work-linux-0.1.0-1-x86_64.pkg.tar.zst`.
- The 33-entry package contains the Rust binary, bounded inspector, metadata,
  SBOM, documentation, icon, desktop/AppStream files, and license. Its path
  inventory contains no DMG, Mach-O app, Electron, `app.asar`, Node modules,
  Python server, build-work script, or copied compat tree.
- `make install-user` published the immutable native release at
  `~/.local/opt/chatgpt-work-linux/current`. The installed binary returned a
  healthy doctor report and its isolated Wayland smoke test passed with
  56/46 ms hide/show handoff and 246,890,496/262,176,768-byte current/peak
  memory. Installer pruning also handled read-only releases left by the
  superseded packaging flow without touching the active or rollback release.
- A separate temporary-prefix transaction confirmed that `uninstall-user.sh`
  removes the application while preserving user profiles by default.

## History cleanup

- `compat/codex-desktop-linux` was removed from all reachable local `main` and
  local `origin/main` snapshots. Rewrite backup refs and reflogs were removed
  and Git garbage collection pruned the copied objects.
- The external `/home/jaideep/programs/codex-desktop-linux` checkout remains
  available as a read-only reference; it is not part of this repository.

## Still requiring deliberate interactive QA

Automated checks do not substitute for user-visible service testing. Before a
release, manually exercise fresh-profile email and Google/Chromium sign-in,
offline loading, an external link, file upload/download, microphone/camera,
screen share, permission deny/allow, screenshot cancellation/success,
`--safe-mode`, and the Chromium fallback on both Wayland and X11. Inspect an
installed native package with the package manager and confirm uninstall
preserves profiles unless `--purge` is explicit.
