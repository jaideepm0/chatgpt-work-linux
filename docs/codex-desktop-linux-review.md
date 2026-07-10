# Complete `codex-desktop-linux` reference review

## Scope

The reference tree at `/home/jaideep/programs/codex-desktop-linux` was reviewed
read-only at commit `f3836c9c225cb0a2868f05bf0bc031f20c57c56f`. The review
covered acquisition, DMG extraction, ASAR patching, optional features, native
module rebuilding, the launcher, application lifecycle, portals, updater,
packaging, install/rollback, diagnostics, and tests. Its 329 main-patcher tests
and 379 optional-feature tests passed at that revision.

The two projects have different upstream constraints. Codex Desktop is an
Electron application whose authenticated app-server protocol can be retained
while its runtime is replaced. The current ChatGPT Work-era macOS application
is a native ARM64 Swift/AppKit application. `chatgpt-work-linux` therefore
reuses engineering practices, not proprietary code, assets, or patching
mechanisms.

## Reference architecture

```text
official Codex DMG
  -> download/cache/extract
  -> ASAR discovery and deterministic JavaScript patch pipeline
  -> Electron replacement + rebuilt native modules
  -> staged Linux application tree
  -> shell supervisor + local asset server + optional integrations
  -> user/system package and Rust updater
```

Important implementation areas are `scripts/lib/dmg.sh`,
`scripts/patches/engine.js`, `scripts/lib/patch-report.js`,
`scripts/lib/build-info.js`, `scripts/lib/native-modules.sh`, the 3,103-line
`launcher/start.sh.template`, `launcher/webview-server.py`,
`scripts/lib/package-common.sh`, and `updater/src/`.

## Practices carried forward

1. **Deterministic capability reporting.** The descriptor engine and patch
   report (`scripts/patches/engine.js`, `scripts/lib/patch-report.js`, and
   `scripts/ci/validate-patch-report.js`) distinguish required capabilities,
   optional skips, drift, and already-applied patches. This project applies the
   same principle through typed feature state, `doctor --json`, strict config
   validation, and tests for every policy branch.
2. **Build provenance.** `scripts/lib/build-info.js` records wrapper commit,
   source artifact, Electron, and patch metadata. This project records the
   upstream observation in `docs/upstream-snapshot.json`, content-addresses user
   releases, remaps build paths, and treats SBOM/provenance as a release gate.
3. **Content verification and atomic publication.** The managed Node runtime
   verifies content hashes before publishing, and updater state uses temporary
   files plus rename. Here every user release contains `SHA256SUMS`, is verified
   before activation, and the `current` symlink is switched last.
4. **XDG separation and ownership checks.** The reference separates config,
   state, cache, data, runtime sockets, and logs, and validates ownership for
   sensitive runtime locations. This project uses strict absolute XDG paths,
   mode-0700 profile directories, mode-0600 atomic state/config writes, and
   injective profile application IDs.
5. **Bounded single-instance handoff.** The reference combines a startup lock
   with a bounded activation socket and has explicit quit/drain paths. Here
   `GApplication` owns the Wayland desktop instance before WebKit data is
   opened, and a profile advisory lock protects non-D-Bus and Chromium modes.
6. **Portal-first Linux integration.** The reference has portal-aware external
   open, desktop capability checks, and explicit fallbacks. This project uses
   Global Shortcuts and interactive Screenshot portals and never installs a
   privileged input device workaround.
7. **Staged package validation.** The reference checks the staged tree before
   installing. This project validates the staged binary, desktop entry,
   AppStream metadata, per-file hashes, package contents, and preserves the
   active version if staging fails.
8. **Broad drift tests.** `scripts/patch-linux-window-ui.test.js` exercises
   minified-name changes, quit paths, XDG behavior, launch handoff, build info,
   and optional feature drift. Equivalent Linux-native tests belong at policy,
   lifecycle, portal-protocol, package, and GUI boundaries here.

## Problems deliberately not copied

| Severity | Reference evidence | Consequence | Response in this project |
|---|---|---|---|
| Critical | `launcher/start.sh.template:2784-2788` always adds `--no-sandbox` and `--disable-gpu-sandbox`. | Removes an essential renderer containment boundary. | WebKit and Chromium sandboxes, TLS verification, and web security can never be disabled by config. |
| Critical | `scripts/lib/install-helpers.sh:161` and `Makefile:191` can remove an active install before its replacement succeeds. | A failed update can leave no working application. | Immutable content-addressed versions are verified first; version-independent integration is staged and `current` changes last. Pacman owns system transactions. |
| Critical | `scripts/lib/dmg.sh:128,425`, `scripts/lib/native-modules.sh:8,286`, and CI `npx --yes` paths admit mutable or live-fetched build inputs. | Upstream drift or registry compromise can alter a nominally identical build. | Runtime builds never fetch the DMG, `Cargo.lock` is mandatory, Arch sources are checksummed, and package builds use `--frozen`. |
| High | Optional regex patches can miss after minifier drift while other feature fragments remain enabled; the audited report had optional skips. | Partially wired native IPC or UI can fail at runtime. | No proprietary minified bundle is patched. Native features are compiled Rust modules with explicit capability and fail-closed policy boundaries. |
| High | Cache/plugin writes occur around `launcher/start.sh.template:3014,3064,3090`; lock timeout can still allow launch. | Two launches can mutate shared state concurrently. | `GApplication` uniqueness precedes persistent WebKit creation; the advisory profile lock never degrades into an unlocked launch. |
| High | Permission monitoring around `launcher/start.sh.template:336,1090` repeatedly walks trees at roughly 100 ms intervals. | Cold-start I/O, wakeups, and poor behavior on HDD/low-end CPUs. | GTK, WebKit, portal, and process events are signal-driven; there is no runtime filesystem polling. |
| High | Updater loops around `updater/src/app.rs:27,397,1004` wake frequently and query package state. | Unnecessary resident CPU, process creation, and failure surface. | No polling updater exists. Web UI updates server-side and binaries update explicitly through the package manager or installer. |
| High | `launcher/start.sh.template:269` and `updater/src/logging.rs:7-12` append logs without a hard bound; a sampled launcher log was about 91 MiB. | Disk growth and retention of sensitive operational metadata. | Runtime diagnostics go to stderr/journald with redacted origins; no application log file is created. |
| High | `scripts/lib/package-common.sh:728` assembles a large tree with duplicate Node/Electron runtimes and backups. | Roughly gigabyte-scale installed size and high update I/O. | One stripped Rust binary reuses distribution GTK/WebKit; only current and previous user releases remain. |
| High | Native modules rebuild in the launch/update workflow (`scripts/lib/native-modules.sh:173`), with large artifacts and buffered child output (`build-info.js:239`, `updater/src/builder.rs:500`). | Startup unpredictability, memory spikes, compiler dependencies on user machines. | Compilation is build-time only; the installed runtime contains no compiler, npm, Node, or native-module rebuild path. |
| Medium | `launcher/webview-server.py:41` serves assets with `no-store`. | Repeated reads and lost immutable caching. | No local server exists; WebKit and the public service use standard HTTP caches. |
| Medium | Renderer accessibility is broadly forced near `launcher/start.sh.template:2537`. | Additional renderer work and unexpected accessibility exposure. | GTK follows the user’s AT-SPI/session configuration; no renderer flag forces accessibility. |
| Medium | A 3,103-line shell script supervises startup and runtime policy. | Weak typing, global state, difficult lifecycle tests, and fragile cleanup. | Shell is limited to fetch/build/install. Rust modules own runtime policy and lifecycle. |
| Medium | Settings persistence visible in patch fixtures uses direct `writeFileSync`; updater config/state validation is uneven. | Torn writes and silently accepted invalid intervals/state. | Config and runtime state reject unknown/unsafe values and use mode-0600 write, fsync, rename, and parent-directory fsync. |
| Medium | The updater can build from a live source checkout and perform npm installs. | Network and source state influence an update after user approval. | Packages are built from a checksummed source archive with frozen Cargo dependencies; installs never compile. |
| Medium | Real Wayland/auth/resource tests are much thinner than patch-string tests. | A green patch pipeline can still ship a broken desktop workflow. | KDE Wayland is the production QA target; X11 is compatibility CI only. The roadmap requires portal, single-instance, offline, OAuth handoff, download/upload, and constrained-resource smoke tests. |

## Authentication lesson

Codex Desktop does not make Google OAuth succeed inside Electron. Its renderer
asks the local app server to start login, opens the returned authorization URL
in the real default browser, and waits for the app-server completion event
(`codex-app/content/webview/assets/app-initial~…js`, login-route assets,
`scripts/patches/main-process/browser.js:321-368`, and login tests around
`scripts/patch-linux-window-ui.test.js:6178-6245`). The app server owns the
tokens, so browser cookies never need to be imported into Electron.

The public ChatGPT service exposes no verified equivalent desktop token broker
for this community client. Copying browser cookies or inventing a callback
protocol would be unsafe. Google also forbids developers from directing OAuth
to an embedded user-agent. The correct current behavior is therefore a clear,
user-approved switch of the entire profile to an installed Chromium app window.
That profile retains the browser sandbox and owns its cookies; the WebKit store
is neither read nor copied.

## Resulting architecture direction

The useful reference qualities are lifecycle discipline, capability reporting,
provenance, atomic installation, XDG isolation, and tests. The target does not
inherit Electron, ASAR rewriting, a local server, runtime compilers, a polling
updater, privileged input injection, or proprietary assets. This gives the
Linux application a smaller and more auditable trusted computing base while
preserving the production behaviors users actually notice: reliable launch,
single-instance commands, persistent sessions, native menus and dialogs,
downloads, permissions, portals, recovery, diagnostics, and rollback.
