# ChatGPT Work upstream assessment

## Verified product and artifact

The current ChatGPT download page describes one desktop application containing
Chat, ChatGPT Work, and Codex. Its macOS link resolves to:

`https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg`

The observation made on 2026-07-13 is:

- compressed DMG: 615,738,501 bytes;
- SHA-256: `c243c94f8de6a51f5530ffe1f8d0c1588733d890ac692e34aaca06d95ba637ca`;
- ETag: `0x8DEE0AB667193CC`;
- version: `26.707.62119`, bundle `5211`;
- product bundle: `com.openai.codex` with ChatGPT display identity;
- runtime: ARM64 macOS Electron application with `app.asar`;
- 10,777 bounded archive entries and 24 selected Mach-O headers;
- the artifact was never executed.

The older
`https://persistent.oaistatic.com/sidekick/public/ChatGPT.dmg` endpoint still
serves the 78.6 MB native ChatGPT Classic application. It is not the current
unified Work/Codex desktop download.

## Structural Work markers

The bounded inspector records exact archive structure without extracting the
proprietary renderer. The unified artifact includes bundled plugin directories
for:

- browser and Chrome integration;
- Computer Use;
- Deep Research;
- record and replay;
- Sites and visualization;
- LaTeX support.

Nested components include the Computer Use service, installer, client, and
lock-screen guardian, four Electron helper applications, and Sparkle updater
components. The plist declares Apple Events, audio capture, camera, desktop
folder, location, and microphone usage categories.

These observations establish that Computer Use and browser integration are
part of the unified desktop distribution. They do not authorize execution of
the Apple helpers, reveal a supported native protocol, or make privileged IPC
safe to expose to remote web content.

## Architecture decision

Although the current artifact contains a portable Electron application plane,
this repository keeps Rust/GTK/WebKitGTK as its primary runtime. The macOS DMG
remains ignored reference input: no Mach-O executable is run, no proprietary
renderer is patched or bundled, and no Apple privileged helper is translated.

Linux parity is implemented as independently testable capability slices:

1. server-delivered Chat/Work UI through the signed-in public service;
2. explicit file selection/upload and safe native download handling;
3. user-initiated portal screenshot, screen sharing, voice, and shortcut;
4. future observation-only local context with preview and per-transfer consent;
5. a separately threat-modeled input-automation phase, never a remote-page
   shell or unrestricted input bridge;
6. package-manager updates, isolated profiles, and bounded diagnostics.

## Branding boundary

The unmodified public ChatGPT icon is the sole permitted upstream asset used
for desktop identification. Application name, About dialog, desktop entry, and
package metadata remain visibly “Unofficial.” No other proprietary application
resource is shipped.
