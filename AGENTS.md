# AGENTS.md

## Purpose

This repository builds `chatgpt-work-linux`, an unofficial, local Linux
compatibility build of OpenAI's unified ChatGPT desktop application, including
the ChatGPT Work and Codex surfaces present in the user's official artifact.
It is not a public-web wrapper and must never silently fall back to one.

The official DMG, extracted application resources, generated compatibility
build, and OpenAI proprietary UI remain local, ignored inputs/outputs. Never
commit or redistribute them. Keep every generated application and desktop
entry visibly labeled as unofficial and not endorsed by OpenAI.

## Architecture rules

- The production runtime is the portable application plane extracted locally
  from the exact allowlisted official unified `ChatGPT.dmg`, adapted to a
  verified Linux Electron runtime. The Rust/GTK/WebKitGTK code is historical
  and is not the default build, installation, or packaging target.
- Accept upstream input only from
  `https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg`. Require HTTPS
  verification, the exact DMG content type, a greater-than-500-MiB size floor,
  a bounded maximum size, complete SHA-256 provenance, archive integrity, and
  an exact reviewed snapshot before transforming it. Do not accept ChatGPT
  Classic or an older public-web wrapper artifact.
- Local extraction and compatibility patching of portable resources are
  permitted solely to build for the current user. Do not execute macOS Mach-O
  binaries. Do not publish the DMG, extracted files, generated app, patched
  ASAR, plugins, helpers, or proprietary UI in releases or native packages.
- Keep the compatibility adapter external, clean, and pinned by exact Git
  commit. Cache an immutable archive by commit; do not vendor the adapter or
  silently follow a mutable branch during a build.
- Every required transformation must be drift detecting and fail closed.
  Require exact or unique anchors, deterministic patch reports, final semantic
  assertions, native dependency checks, and staged validation before atomic
  publication. A missed or ambiguous required patch must stop the build and
  preserve the active installation.
- Run the packaged renderer from the registered `app://` scheme with
  `app.isPackaged=true`. Do not add a localhost asset server, development URL,
  duplicated external renderer tree, or public-web fallback.
- Never disable the Electron/Chromium renderer or GPU sandboxes, TLS
  verification, or web security. Reject `--no-sandbox`,
  `--disable-gpu-sandbox`, and equivalent bypasses in generated launchers.
- Ordinary remote HTTPS content must not receive arbitrary native IPC or shell
  access. Preserve the packaged application's reviewed local protocol boundary
  and do not add a broad preload bridge.
- Wayland/Ozone is the production display path. Use user-consented XDG portals
  for screenshots, pointer, keyboard, and other privileged desktop operations.
  Disable direct `/dev/uinput` and `ydotool` fallbacks on Wayland, and recheck
  the target window immediately before input after portal setup.
- Keep Electron runtime state in an isolated validated XDG profile. Use the
  canonical Codex home (`$CODEX_HOME` or `~/.codex`) for local task, project,
  and CLI history so the unified app does not split or duplicate the user's
  Codex data. Test and profiling launchers may override it with a disposable
  `CHATGPT_WORK_CODEX_HOME`. Preserve single-instance behavior, bounded
  stderr/journald diagnostics, and explicit user initiation for privileged
  setup or dependency installation.
- Performance and resource consumption are release gates. Avoid duplicate
  renderer payloads, repeated full builds, unbounded adapter/Cargo caches,
  unnecessary background processes, unconditional prewarming, and persistent
  polling. Prefer documented runtime preferences over renderer/style patches
  when they provide equivalent savings. Measure startup, settled CPU, process
  count, and proportional memory under a two-core CPU set and
  constrained-memory lane before handoff.
- There is no persistent polling daemon or unattended runtime code replacement.
  Upstream checks are metadata-only and rate-limited; refresh, adapter update,
  build, validation, and installation are explicit transactions. Install
  immutable versions and atomically switch `current`, retaining `previous`.
- Shell, Python, and Node utilities are build and validation tooling. Use strict
  error handling, quote paths, constrain network destinations and extraction,
  publish outputs atomically, and preserve the active build/install on failure.
- The sole source-controlled upstream asset exception is the unmodified public
  ChatGPT application icon requested for desktop identification. Record its
  artifact/hash provenance and OpenAI ownership.

## Source map

- `scripts/fetch-upstream.sh` / `inspect-upstream.py`: bounded official DMG
  acquisition into the private XDG cache, provenance, integrity, and
  structural inspection.
- `scripts/check-upstream.sh` / `update-user.sh`: cached metadata-only checks
  and an explicit full update transaction; never background polling.
- `scripts/prepare-compat-adapter.sh`: clean commit-pinned external adapter
  cache.
- `scripts/build-work-app.sh`: production staging, hardening assertions, and
  atomic publication.
- `scripts/patch-work-asar.py`: exact-size packaged-renderer compatibility
  changes; anchor drift is fatal.
- `scripts/patch-compat-adapter.py`: exact reviewed adapter drift fixes for the
  current upstream application snapshot.
- `scripts/patch-computer-use-wayland.py`: portal-only Wayland backend policy
  and last-moment target-focus validation.
- `scripts/configure-work-runtime.py`: packaged identity, `app://`, XDG,
  Wayland/Ozone, lifecycle, and bounded-log configuration.
- `scripts/validate-work-patch-report.py`: required upstream capability gate
  enforcement.
- `scripts/install-user.sh`: immutable user versions and atomic
  `current`/`previous` switch.
- `scripts/migrate-codex-history.py`: one-time, transactional recovery of
  sessions accidentally written to the former isolated compatibility home.
- `scripts/smoke-wayland.sh` / `scripts/profile-runtime.sh` /
  `tests/runtime_hardening.sh`: production runtime, performance, and generated
  launcher security gates.
- `src/`: historical Rust/GTK public-web client; do not substitute it for the
  production desktop target.
- `packaging/`: desktop/AppStream metadata and source-only packaging material;
  never include generated proprietary payloads.
- `docs/`: architecture decisions, artifact/adapter audits, current snapshot,
  and validation evidence.

## Validation

Run before handoff:

```bash
make check
make build
make doctor
make smoke-wayland
make profile-runtime
make install-user
chatgpt-work-linux doctor --json
chatgpt-work-linux computer-use-doctor
```

Confirm the running application uses the packaged `app://` renderer, reports
packaged Linux identity, creates a sandboxed Wayland renderer, has no localhost
asset server or sandbox-bypass flags, and completes the app-server and Computer
Use MCP handshakes. Verify the unified desktop UI rather than the public
ChatGPT website.

For runtime changes, exercise single-instance/toggle, authentication, offline
recovery, external links, uploads/downloads, portal cancellation/success,
Computer Use confirmation and target-focus behavior, restart, and rollback.
Ensure uninstall preserves profiles unless `--purge` is explicit.

Performance-sensitive changes must be measured with two permitted CPU cores and
a 768 MiB memory limit. Record launch time, settled CPU, process count,
proportional/peak memory, and generated size. Treat an OOM as a failed gate and
record it honestly; do not weaken sandboxing or impose an unsafe heap cap to
manufacture a pass. Do not use `target-cpu=native`; generated Linux components
must run on older x86_64 hardware.
