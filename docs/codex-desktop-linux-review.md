# External compatibility adapter review

Date: 2026-07-17

The external checkout at `~/programs/codex-desktop-linux` was fetched and
reviewed at `b24e5ff2cfabbd1a366f711229b3b115aa4397fe`. It is not vendored,
submoduled, or copied into this repository. `prepare-compat-adapter.sh` requires
a clean checkout, resolves a commit, and creates an immutable cache archive by
commit hash.

## Components used

- DMG acquisition/extraction and structural validation.
- Deterministic patch engine and required/optional capability report.
- Electron acquisition, native-module rebuild, app-server/plugin staging, and
  Linux platform patches.
- Desktop integrations needed by the unified local application plane.

The exact accepted report for each local build is stored under
`.work/reports/<version>/`. For ChatGPT `26.715.21425`, the upstream-build
acceptance profile passed with eight recorded optional drift warnings; all
required capability and security patches passed.

## Components overridden by this repository

The generated adapter launcher was not accepted unchanged:

| Adapter behavior | Repository correction |
|---|---|
| Executable named `electron`, leaving `app.isPackaged=false` | Rename to `chatgpt-work-linux-bin` and validate packaged mode |
| Python localhost server and `ELECTRON_RENDERER_URL` | Remove server and force packaged `app://` renderer |
| `--no-sandbox` and `--disable-gpu-sandbox` | Remove and reject both flags at build/smoke time |
| Startup Quick Chat prewarm | Exact same-size ASAR patch to keep it lazy |
| Linux Computer Use rollout remains unavailable in the final renderer | Exact same-size host/feature gate patch plus semantic validation |
| Wayland input can select uinput/`ydotool` and keyboard focus can change after portal setup | Exact-source transform forces the XDG portal, blocks unsafe fallbacks, and revalidates targeted focus immediately before input |
| Broad/default runtime identity | Isolated Electron XDG profile, canonical Codex home, and stable desktop ID |
| Potentially growing launcher log | Bound and trim the operational log |
| Mutable install replacement | Immutable content-addressed versions and atomic symlink switch |

## Trust and update policy

The adapter is build tooling, not a runtime dependency fetched on launch. A
dirty reference checkout is rejected. Network refresh is explicit; offline
builds may reuse an already archived exact commit. Required patch misses,
ambiguous repository transformations, artifact drift, unresolved libraries,
wrong renderer origin, or sandbox bypasses stop the build before publication.

Generated proprietary application resources, the DMG, adapter archive, and
reports are ignored. Only automation, provenance, tests, and the public icon
provenance belong in Git.
