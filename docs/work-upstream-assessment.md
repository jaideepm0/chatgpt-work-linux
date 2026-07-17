# ChatGPT Work upstream assessment

## Verified product and artifact

OpenAI now distributes a unified desktop application containing Chat, Work,
and Codex. The macOS download link resolves to:

`https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg`

Observation on 2026-07-17:

| Field | Value |
|---|---|
| Size | 618,657,103 bytes (590 MiB) |
| SHA-256 | `ff459150991612007549270d2d28c5e78cec6bd6ac200a7ada5ed6c031369b87` |
| Last-Modified | `Fri, 17 Jul 2026 02:08:05 GMT` |
| ETag | `0x8DEE3A83D124BF1` |
| Display/version | ChatGPT `26.715.21425` (bundle `5488`) |
| Bundle identifier | `com.openai.codex` |
| Runtime | Electron `42.3.0`, ARM64 macOS host |
| ASAR entries | 10,778 |

The 78 MiB legacy/classic download and the Codex-named DMG are not accepted as
inputs. The downloader allowlists the URL above and rejects artifacts at or
below 500 MiB before publication.

## Product evidence from the bundle

The artifact contains the portable unified application plane, local app-server
and CLI resources, browser/chrome/computer-use/deep-research/latex/
record-and-replay/sites/visualize plugins, document and presentation runtimes,
scheduled-work UI, Sites, pull-request and repository surfaces, Quick Chat,
and remote-control resources. Availability is still gated by account,
server-side flags, and platform capability checks.

The public `chatgpt.com/work/` route is a marketing page. Loading it in GTK,
WebKit, Chromium app mode, or a generic Electron shell does not reproduce the
desktop Work product. The packaged application plane and local app-server are
therefore required.

## Linux strategy

The macOS executable and Apple-only helpers are never executed. A clean,
commit-pinned external adapter extracts the artifact, applies deterministic
Linux patches, supplies Electron 42 for Linux, and rebuilds native modules.
This repository then applies stricter runtime invariants:

- packaged executable identity and `app.isPackaged=true`;
- `app://` renderer with no localhost/Python asset server;
- Chromium renderer sandbox retained;
- Wayland Ozone and compositor-native decorations;
- no unconditional startup Quick Chat window;
- isolated XDG Electron profile, canonical Codex task home, bounded
  diagnostics, and immutable atomic installation.

The generated application and proprietary resources remain ignored local
outputs and must not be redistributed.

## Feature boundary

The unified local renderer may use the packaged app-server protocol and the
adapter's validated Linux integrations. Arbitrary remote HTTPS pages must not
receive a shell or privileged native bridge. User-initiated portal actions and
computer-use controls must stay visible, cancellable, and scoped to the active
session.
