# Upstream feature and Linux parity audit

Date: 2026-07-13

## Evidence boundary

This audit uses the official unified ChatGPT macOS artifact linked by the
current ChatGPT download page. The artifact was never executed.
`scripts/inspect-upstream.py` performed an integrity test, parsed the primary
plist and selected Mach-O headers, and inventoried exact archive component and
plugin names. It did not extract proprietary UI, decode private IPC, or
establish account entitlement. The complete deterministic evidence is in
`docs/upstream-snapshot.json`.

The external `codex-desktop-linux` checkout is reviewed separately for Linux
engineering lessons. Its optional patches are not upstream-product evidence
and none of its source is vendored here.

## Verified artifact

| Field | Observation |
|---|---|
| Official URL | `https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg` |
| Version | `26.707.62119` (`5211`) |
| Artifact | 615,738,501 bytes, SHA-256 `c243c94f8de6a51f5530ffe1f8d0c1588733d890ac692e34aaca06d95ba637ca` |
| Runtime | Electron application for ARM64 macOS with `app.asar` |
| Structural inventory | 10,777 entries, 24 selected Mach-O headers |
| Bundled plugins | browser, chrome, computer-use, deep-research, latex, record-and-replay, sites, visualize |

## Product surfaces

Official product documentation describes the unified desktop app as containing
Chat, Work, and Codex. Work can create documents, spreadsheets,
presentations, reports, and Sites; use connected plugins and a built-in
browser; run scheduled work; and use local files and apps. Computer Use can
click, type, and move files across desktop apps and the browser while actions
remain subject to user or administrator controls.

The binary structure corroborates those claims:

| Area | Structural evidence |
|---|---|
| Browser | `browser` and `chrome` bundled plugins |
| Computer Use | bundled plugin, service app, installer, client, and lock-screen guardian |
| Research and creation | `deep-research`, `sites`, `visualize`, and `latex` plugins |
| Demonstration/automation | `record-and-replay` plugin |
| Desktop integration | Apple Events, audio, camera, desktop-folder, location, and microphone declarations |
| Runtime | packaged ASAR, Electron helper apps, updater XPC components |

Presence establishes shipped capability code, not rollout, plan entitlement,
or a supported cross-platform API.

## Current Linux coverage

| Capability | Linux status | Boundary |
|---|---|---|
| Public Chat and server-delivered Work UI | Available when the account exposes it | Public `https://chatgpt.com` surface only |
| Isolated profiles and private sessions | Implemented | Separate XDG data/cache/state per profile |
| Navigation and external links | Implemented | HTTPS policy; unsafe schemes blocked |
| Upload/download | Implemented | User chooser and sanitized unique filenames |
| Voice/camera/screen share/location/notifications | Implemented as ask/allow/deny | Trusted top-level sender checks |
| Screenshot for prompting | Implemented | User-initiated Screenshot portal and clipboard |
| Global shortcut/companion | Implemented | Global Shortcuts portal |
| Host settings | Implemented | Atomic mode-0600 configuration |
| Built-in browser agent | Not implemented | No private browser protocol or bundled browser |
| General Computer Use | Not implemented | No remote-content IPC, `uinput`, `ydotool`, or Apple helper port |
| Record and Replay | Not implemented | No proprietary plugin/runtime port |
| Updates | Package/user transactions | No Sparkle or polling updater |

## Settings review

The native client exposes only host-owned decisions: engine, performance,
reduced motion, page cache, microphone, camera, display capture, location,
notifications, cross-site sign-in storage, global shortcut, and
close-to-background. Configuration rejects unknown fields and unsafe Chromium
arguments, saves atomically with mode 0600, and fails closed for untrusted
permission senders.

The unified upstream product also has Browser data/download settings, plugin
management, Computer Use access controls, account/model/memory settings, and
enterprise policy. Those remain service/product owned and are not imitated via
private contracts.

## Computer Use strategy

1. Keep the current user-initiated screenshot flow as the only default desktop
   observation capability.
2. Prototype observation-only local context outside the default runtime:
   explicit target choice, portal screenshot or bounded AT-SPI tree, redaction
   preview, strict limits, one-transfer approval, cancellation, and audit log.
3. Never expose the prototype to remote WebKit content. A trusted local agent
   may use only a typed, versioned, session-scoped protocol.
4. Treat input as a separate high-risk phase. Require verified focus,
   per-action preview/approval, emergency stop, revocation, and compositor
   mediation. Do not install unrestricted `uinput`, `ydotool`, or a shell
   bridge in the default application.
5. Account and administrator rollout controls remain authoritative; local code
   must not force-enable server-disabled product flags.

## Acceptance order

The first target is KDE Wayland, followed by X11 compatibility. Each slice must
pass single-instance/toggle, offline recovery, external-link, upload/download,
permission deny/allow, screenshot cancellation/success, safe mode, Chromium
fallback, package-content, and profile-preserving uninstall checks. Sensitive
changes also run under two cores and 768 MiB with generic x86_64 output.
