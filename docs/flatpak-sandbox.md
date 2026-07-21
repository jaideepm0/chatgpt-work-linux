# Flatpak status

Product Flatpak packaging is intentionally disabled.

The previous manifest built the historical Rust/WebKit public-web client. That
client is not the unified ChatGPT desktop application and must never be shipped
as a fallback. The production product plane is generated locally from the exact
reviewed official `ChatGPT.dmg`, and repository policy prohibits redistributing
the DMG, extracted UI, patched ASAR, plugins, helpers, or generated application
inside a Flatpak.

The checked-in manifest therefore fails closed. A future Flatpak design is
acceptable only if it distributes source tooling, performs the proprietary
transformation locally for the current user, preserves `app://`, Electron and
renderer sandboxes, Wayland portals, canonical Codex history, immutable local
versions, and rollback, and passes the same release gates as `make update-user`.
