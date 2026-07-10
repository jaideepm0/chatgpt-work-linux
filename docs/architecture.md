# Architecture

## Decision summary

`chatgpt-work-linux` is a clean, Wayland-first Linux application, not a
translated macOS app or an Electron repack. The public `https://chatgpt.com/`
service is the remote product plane. A native Rust controller owns application
lifecycle, windows, profiles, policy, permissions, portals, settings,
downloads, notifications, recovery, diagnostics, and installation. System
WebKitGTK is the primary renderer; installed-Chromium and external-browser
modes are compatibility engines. There is no private API client, remote-page
preload, Node bridge, injected DOM automation, local HTTP server, or bundled
OpenAI binary.

The window uses normal compositor decorations and a native GTK application
menu. KDE/KWin therefore owns move, resize, shadows, scaling, and window
controls; the application does not draw or emulate a macOS titlebar.

The choice is optimized for older hardware:

- WebKitGTK reuses the distribution's patched shared engine instead of shipping
  another ~150 MB browser runtime.
- A small Rust main process owns native policy and event handling.
- One website data context is shared by a profile's lazily created windows.
- No local server, plugin cache, compiler, updater daemon, or background polling
  exists in the launch path.
- Chromium app mode remains available when WebKit/site compatibility matters
  more than minimum footprint.
- Efficient mode gives WebKit a supported 512–1024 MiB per-process
  memory-pressure limit derived from the effective host/cgroup budget. Balanced
  mode retains WebKit defaults to avoid aggressive cache eviction.

GTK 4 with WebKitGTK 6 is the planned toolkit migration because WebKitGTK 6 is
the GTK 4 API and makes cross-site process swapping mandatory. It is not forced
into this baseline: on the target Arch system both 4.1 and 6.0 ship WebKit
2.52.4, while installing 6.0 adds another roughly 130 MiB shared runtime. The
current 4.1 API already uses maintained libsoup 3 and has the required sandbox,
permission, website-data, and memory-pressure APIs. Migration is gated on
equivalent KDE Wayland lifecycle, portal, auth, and low-memory tests.

## Component map

```text
desktop / CLI
          │
          ▼
GTK GApplication ─── profile-scoped single instance on KDE Wayland
          │
          ├── URL + permission policy (deny/externalize/fail closed)
          ├── standard compositor frame + native GTK actions/menu/settings
          ├── XDG paths and validated, atomically written config/state
          ├── XDG portals (global shortcut, screenshot picker)
          ├── downloads + desktop notifications
          ├── Google OAuth → approved whole-profile Chromium handoff
          └── bounded crash / offline / safe-mode handling
                    │
          ┌─────────┴─────────┐
          ▼                   ▼
 system WebKitGTK       installed Chromium app mode
 (default, light)       (compatibility fallback)
          │                   │
          └─────────┬─────────┘
                    ▼
             https://chatgpt.com/

optional developer-only lane:
official HTTPS DMG → bounded atomic cache → metadata-only inspector → JSON
```

## Runtime modules

- `cli.rs`: stable command surface and validated profile names.
- `paths.rs`: XDG config/data/cache/state/download paths and mode `0700`
  profile directories.
- `config.rs`: strict TOML schema, safe defaults, adaptive performance preset,
  cgroup-aware memory policy, and atomic private writes. Unknown keys and
  insecure start URLs fail validation.
- `policy.rs`: exact URL disposition, trusted-origin permission boundary, and
  download-name sanitization. Suffix comparisons cannot be fooled by
  `chatgpt.com.evil.example`.
- `gui.rs`: GApplication instance ownership, windows, WebKit context/settings,
  native actions/menu/settings, navigation, permission prompts, downloads,
  notifications, crash recovery, companion mode, and screenshot clipboard
  handoff.
- `shortcut.rs` / `capture.rs`: short-lived portal workers connected to GTK by
  local Unix socket pairs; remote page content cannot invoke either worker.
- `engine.rs`: Chromium discovery/app-mode launch and system-browser handoff.
- `doctor.rs`: read-only JSON/text diagnostics without loading the page.

## Security boundaries

The remote page is treated as untrusted web content even though its origin is
first party.

1. Only HTTPS first-party suffixes (`chatgpt.com`, `openai.com`, `oaistatic.com`,
   `oaiusercontent.com`) and a short authentication-host list remain inside the
   webview. HTTP and unrelated HTTPS links open in the system browser. File,
   JavaScript, and data top-level URLs are blocked.
2. Permission requests are denied unless the current top-level URI is an HTTPS
   first-party origin. Location defaults to denied; microphone, camera,
   display capture, notifications, and narrowly scoped cross-site sign-in
   storage are explicit decisions. Unknown request types fail closed.
3. File/universal access from file URLs and automatic JavaScript popups are
   disabled. Developer tools are disabled in release settings.
4. WebKit uses system TLS and its sandboxed multi-process model. No certificate
   error bypass or sandbox-disabling option exists. Chromium fallback also
   retains its sandbox and web security.
5. No native IPC object is exposed to JavaScript. Portal actions originate from
   native buttons/shortcuts, not page messages.
6. Each validated profile has separate cookies/data/cache and a separate D-Bus
   application ID. `--private` uses an ephemeral website-data manager.
7. Logs go to stderr/journald and do not intentionally log page bodies, prompts,
   cookie values, or credentials.
8. Google OAuth is never directed into the embedded user agent. A native,
   user-approved dialog can restart the complete profile in an installed
   Chromium app window. No cookie, token, or key-store material crosses engine
   boundaries.

The Global Shortcuts portal is used because it works on Wayland without global
input hooks (and also provides X11 compatibility)
without unrestricted input hooks; its API binds shortcuts to a user-approved
session. See the [portal specification](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html).
Screenshots use the interactive
[Screenshot portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Screenshot.html)
and are copied to the clipboard for explicit user paste, avoiding remote DOM
injection.

## Performance model

| Preset | GPU policy | WebGL | Page cache | Web-process limit | Intended use |
|---|---|---:|---:|---:|---|
| `auto` | on demand | adaptive | adaptive | adaptive | default |
| `efficient` | on demand | off | off | 512–1024 MiB | older/low-memory hardware |
| `balanced` | on demand | on | on | WebKit default | normal desktop |
| `quality` | always | on | on | WebKit default | stable modern GPU |
| `--safe-mode` | never | off | configured | configured | GPU/renderer recovery |

The generic Rust target is retained; release builds never use
`target-cpu=native`, AVX-only flags, or host-specific profile data. Release
settings use one codegen unit, thin LTO, symbol stripping, and panic abort. The
public web application remains the dominant RSS/network cost.

Performance acceptance targets (measured outside page/network variability):

- packaged application below 20 MiB;
- native-shell cold start below two seconds;
- settled shell idle CPU below 1%;
- no leaked portal/helper processes after exit;
- usable launch under a two-core, 768 MiB cgroup, with WebKit page memory
  pressure reported rather than an unbounded reload loop.

Example constrained run:

```bash
systemd-run --user --scope --collect \
  -p MemoryMax=768M -p CPUQuota=100% \
  taskset -c 0,1 chatgpt-work-linux --safe-mode
```

## Failure handling

- A WebKit process termination records a rolling 60-second crash window. At
  most three automatic reloads occur with 0.5/1/2-second backoff; further
  crashes stop the loop and recommend safe/Chromium mode.
- Network/TLS load failures preserve native controls and give a concrete
  diagnostic message. TLS inspection is not bypassed; OpenAI's
  [network guidance](https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps)
  is the escalation path.
- Downloads cannot traverse directories, never overwrite an existing file,
  and receive deterministic collision suffixes.
- Invalid config is ignored with a visible warning; the user's malformed file
  is not overwritten.
- User installs verify the staged binary before an atomic symlink exchange and
  retain the previous content-addressed version.
- User releases contain a deterministic per-file `SHA256SUMS`; Arch packages
  build from a checksummed source archive with frozen Cargo dependencies.

## Feature mapping and limits

The loaded web service owns chats, Work tasks, connectors, Codex, documents,
presentations, search, and account/server rollouts. The Linux shell supplies
only OS integration.

- File uploads use WebKit's native chooser.
- Downloads and completion notifications are native.
- Voice uses normal WebRTC/getUserMedia with an explicit permission prompt.
- Screen sharing uses the browser/desktop portal stack when supported.
- Companion mode is a responsive 480×720 always-on-top window; compositors may
  apply their own Wayland focus/z-order policy.
- Screenshots are portal-selected and clipboard-mediated.
- Apple Events, Handoff, native Contacts/Calendar/Reminders, and macOS
  Accessibility are unsupported.
- “Work with Apps” is not approximated with silent AT-SPI scraping. A future
  integration must show exactly what context will be sent and require approval.

## Build, provenance, and update model

Normal builds are offline with respect to OpenAI assets and use Cargo.lock.
Linux package managers own binary updates; there is no privileged or polling
updater. The server-served UI updates independently.

The optional upstream lane is isolated from runtime. `fetch-upstream.sh`
allowlists one official HTTPS URL, applies time/size/stall limits, resumes only
against matching state, atomically publishes a complete DMG, and invokes a
bounded metadata inspector. The inspector never executes or packages artifact
content. Because the URL is a mutable alias and OpenAI does not publish a
SHA-256 beside it, final signing/notarization verification remains a macOS
release-maintainer task.
