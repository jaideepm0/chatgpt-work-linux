# Audit and improvement plan

Date: 2026-07-17

## Completed baseline

- Removed the copied `compat/codex-desktop-linux` tree and all build coupling
  to a vendored reference checkout.
- Restored the correct official `ChatGPT.dmg` endpoint and enforced a greater
  than 500 MiB gate plus exact snapshot size/hash validation.
- Updated against external adapter commit
  `b24e5ff2cfabbd1a366f711229b3b115aa4397fe` from the ignored cache; no adapter
  checkout is vendored in this repository. The build applies its documented,
  drift-detecting portal-only Wayland input transform to that disposable cache
  copy.
- Replaced the public-web wrapper as the default build/install target with the
  unified ChatGPT Electron application plane.
- Removed the generated Python localhost server and sandbox-disable flags.
- Fixed `app.isPackaged` by renaming the Electron executable and forced the
  packaged `app://` origin.
- Removed the unconditional Quick Chat prewarm responsible for the blank
  startup overlay while retaining on-demand Quick Chat.
- Made all five Linux Computer Use UI/backend integration patches mandatory so
  an installed backend cannot be filtered out as unavailable in local tasks.
- Forced Wayland pointer/keyboard input through XDG portals, blocked direct
  input fallbacks, and added last-moment target focus verification to fail
  closed when another window takes focus during portal setup.
- Added reproducible build, exact adapter provenance, immutable user install,
  rollback, doctor output, and a Wayland sandbox/origin/process smoke test.
- Restored the canonical Codex task home, transactionally recovered the four
  threads written by the former split profile, and verified both old and
  recovered threads through the unified sidebar and app-server.
- Added a two-core constrained resource profiler and selected Chromium reduced
  motion after an A/B run reduced settled virtual-Wayland CPU from 88.44% to
  5.05% without a renderer/style patch.

## Release gates

1. `make check`, `make build`, `make doctor`, and `make smoke-wayland` must pass.
2. Artifact URL, size, hash, application version, Electron version, and adapter
   commit must be recorded together.
3. Every required adapter patch and repository hardening invariant must pass;
   optional skips must be reviewed rather than hidden.
4. Confirm one main window at startup, `app://` renderer origin,
   `app.isPackaged=true`, sandboxed renderer, Wayland Ozone, app-server
   handshake, and absence of a localhost asset server.
5. Exercise sign-in, offline recovery, external URLs, upload/download,
   microphone/screen permissions, Quick Chat, Sites, plugins, scheduled work,
   computer use, and clean shutdown with an entitled account.
6. Confirm a failed update leaves `current` intact and uninstall preserves the
   profile unless `--purge` is explicit.

## Next hardening work

1. Add fixture-level tests for every repository launcher/ASAR transformation.
2. Add crash-loop backoff and automated child-process cleanup assertions.
3. Reduce the upstream renderer's proportional memory footprint; CPU is now
   bounded by the reduced-motion default, but measured PSS remains high.
4. Exercise KDE and GNOME portal behavior across multi-monitor scale factors,
   permission denial/cancellation, and restored grants.
5. Produce native package formats only after they install this verified
   Electron build; never expose the retained historical Rust wrapper through a
   release/package target.
