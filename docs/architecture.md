# Production architecture

## Decision

`chatgpt-work-linux` is a native Rust/GTK controller for the public ChatGPT web
service. WebKitGTK is the primary renderer. An installed Chromium app window
and the system browser are explicit compatibility engines. The official macOS
DMG is ignored reference input and is never executed, translated, patched, or
included in a Linux package.

The official `26.707.62119` app is an ARM64 macOS Electron application with a
portable ASAR plus proprietary helpers and plugins. Its structure helps detect
product drift, but repository policy keeps it outside the Linux runtime: no
ASAR patching, runtime substitution, or native helper execution is permitted.
See `upstream-feature-audit.md`.

## Runtime flow

```text
desktop/CLI activation
        |
        v
validated profile + strict config
        |
        v
GApplication single-instance ownership
        |
        +--> existing instance: typed activation only
        |
        v
shared profile WebKit context
        |
        +--> trusted ChatGPT/auth HTTPS navigation
        +--> external HTTPS URL -> system browser
        +--> unsafe/untrusted native request -> deny
        +--> user upload/download -> chooser/policy
        +--> media permission -> trusted sender + local policy
        +--> screenshot/shortcut -> user-initiated XDG portal worker
```

No remote page receives a shell, filesystem, process, accessibility, or native
IPC bridge. Shell scripts are build/install tools only.

## Security boundaries

1. `src/policy.rs` owns trusted origin/scheme, website-data, and filename
   decisions. Every policy change requires tests and defaults to denial.
2. `GApplication` uniqueness is acquired before shared browser state is opened.
   Each validated profile has separate data, cache, state, and application ID.
3. Permission requests are accepted only for trusted top-level pages and are
   subject to local ask/allow/deny policy. Capture state stays visible.
4. Screenshot and global-shortcut work is isolated in portal workers and begins
   only after a user action. Portal denial/cancellation is a normal result.
5. WebKit/Chromium sandboxing, TLS verification, CSP, and web security are never
   disabled. Chromium arguments are allowlisted.
6. Configuration and runtime state use private directories and atomic mode-0600
   files. Diagnostics redact URL path/query data and default to stderr/journald.
7. Downloads use sanitized unique filenames. Uploads use the desktop chooser;
   the application never grants a remote page general filesystem access.
8. Updates are explicit package-manager or atomic user-install transactions.
   There is no polling updater or unbounded file log.

## Settings ownership

The host owns engine selection, performance, media/privacy decisions, portal
shortcut, and window lifecycle. The ChatGPT service owns account, model,
memory, custom-instruction, connector, subscription, and product-feature
settings. Keeping that split prevents stale local replicas and avoids a private
settings API.

## Computer-use boundary

The default application provides user-initiated screenshot capture, not general
computer control. Remote WebKit content cannot enumerate apps, read AT-SPI,
inject input, or execute commands.

A future local-context prototype must be a separate opt-in component and begin
observation-only: explicit target selection, portal screenshot or bounded
AT-SPI snapshot, redaction preview, one transfer approval, cancellation, and
an audit record. Input automation is a later independent decision and cannot
use unrestricted `uinput`, `ydotool`, or a remote-page bridge.

## Failure and recovery

- Invalid config is rejected and safe defaults are used with a visible warning.
- Unsafe navigation and permission ambiguity fail closed.
- Web-process failures use bounded recovery; safe mode disables risky rendering
  features without weakening web security.
- Google OAuth moves to a user-approved installed Chromium/browser flow; cookies
  are not copied between engines.
- A failed build/install never replaces the active release. User profiles are
  preserved unless purge is explicit.

## Upstream observation flow

```text
allowlisted official HTTPS URL
        |
        v
bounded resumable ignored DMG
        |
        v
7-Zip integrity/listing + selected plist/Mach-O headers
        |
        v
deterministic metadata candidate + drift summary
        |
        v
atomic docs/upstream-snapshot.json publication
```

The inspection path never runs Mach-O code or copies proprietary UI. A new
bundle name is evidence for review, not permission to add a bridge or loosen a
policy.

## Performance and portability

The default runtime reuses distribution GTK/WebKit libraries and contains no
Electron/Node/browser bundle. It is event-driven, has no updater/filesystem
polling, and avoids hidden prewarmed windows. Release output does not use
`target-cpu=native` and must pass the two-core/768 MiB lane on older x86_64
hardware.
