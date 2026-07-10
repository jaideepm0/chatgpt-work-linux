# ChatGPT Work upstream assessment

## Verified product and artifact

OpenAI describes ChatGPT Work as a new agent that gathers context, creates
documents, presentations, spreadsheets, sites, reports, and analyses, can run
or monitor delegated work, and asks before taking actions. OpenAI says it is
available on macOS desktop first, with desktop providing deeper access to
local files, apps, browser access, and Codex.

The official desktop page currently links the macOS button to:

`https://persistent.oaistatic.com/sidekick/public/ChatGPT.dmg`

The observation made on 2026-07-10 is:

- compressed DMG: 78,575,566 bytes;
- expanded DMG payload: 203,461,632 bytes;
- SHA-256: `49b33cadd2ec659b76352384f7ebd332a7ec7029663365a9f720f4a251d3b8d1`;
- version: `1.2026.183` (`1783607847`), commit `3dab2ed0d5`;
- product bundle: `com.openai.chat`;
- runtime: ARM64 native Swift/AppKit/SwiftUI with `ChatGPT.framework`;
- no Electron runtime, `app.asar`, or portable web application bundle.

The 561,015,842-byte file at
`/home/jaideep/programs/codex-desktop-linux/Codex.dmg` is the Codex artifact.
It is not the ChatGPT Work download. The mutable official ChatGPT URL and the
local file match the response ETag, Last-Modified value, Content-Length, and
Content-MD5 observed during this assessment.

## Structural Work markers

The bounded metadata inspector now records exact resource-bundle names without
extracting UI resources or executing the application. The current artifact
contains markers for:

- automations and action review;
- connectors and project connectors;
- file library, presentations, sites, text editor, and writing blocks;
- data visualization and code execution;
- meetings and desktop integration.

These markers corroborate the public Work description. They do not establish
account entitlement, reveal a supported API, or make the Apple-native modules
portable. See `docs/upstream-snapshot.json` for the deterministic machine-readable
inventory.

## Architecture decision

Codex Desktop can be adapted because its upstream application is Electron and
ships a portable renderer plus app-server protocol. ChatGPT Work is different:
its desktop implementation is native Apple code and its private service
contracts are not a supported integration surface. Rehosting that executable
on Linux is neither technically viable nor a robust product architecture.

The Linux product therefore keeps a small Rust/GTK controller and the public
ChatGPT service as the remote product plane. Linux-native Work parity is added
only in independently testable capability slices:

1. server-delivered Work UI and artifacts through the signed-in public service;
2. explicit file selection/upload and safe native download/open flows;
3. user-initiated portal screenshot, screen sharing, voice, and global shortcut;
4. future browser/IDE context only through a documented, previewed,
   least-privilege integration with per-action approval;
5. package-manager updates, isolated profiles, and bounded diagnostics.

Remote content never receives a general native bridge. A future integration
must have typed requests, an allowlisted capability, visible context preview,
hard byte/time limits, cancellation, and an approval record. Unsupported or
ambiguous requests fail closed.

## Branding boundary

At the user's request the Linux desktop entry uses the unmodified official
ChatGPT application icon so the service is recognizable. The application name
and About dialog remain explicitly “Unofficial,” and README/AppStream metadata
state that OpenAI owns the icon and ChatGPT marks and does not endorse this
project. No other proprietary UI assets are included.
