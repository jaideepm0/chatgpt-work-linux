# Audit and improvement plan

Date: 2026-07-13

## Completed baseline

- Removed the copied `compat/codex-desktop-linux` tree and all build coupling
  to a vendored reference checkout.
- Restored the correct official `ChatGPT.dmg` endpoint and enforced a greater
  than 500 MiB gate plus exact snapshot size/hash validation.
- Updated against external adapter commit
  `bce8d36f72eda4cabfbf32a95054e6fc79737722` without modifying that checkout.
- Replaced the public-web wrapper as the default build/install target with the
  unified ChatGPT Electron application plane.
- Removed the generated Python localhost server and sandbox-disable flags.
- Fixed `app.isPackaged` by renaming the Electron executable and forced the
  packaged `app://` origin.
- Removed the unconditional Quick Chat prewarm responsible for the blank
  startup overlay while retaining on-demand Quick Chat.
- Added reproducible build, exact adapter provenance, immutable user install,
  rollback, doctor output, and a Wayland sandbox/origin/process smoke test.

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
3. Measure cold/warm start, renderer count, idle CPU, and peak RSS; document
   graceful behavior under two cores and 768 MiB.
4. Exercise KDE and GNOME portal behavior across multi-monitor scale factors,
   permission denial/cancellation, and restored grants.
5. Produce native package formats only after they install this verified
   Electron build; never expose the retained historical Rust wrapper through a
   release/package target.
