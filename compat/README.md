# Compatibility engine provenance

`codex-desktop-linux/` is a build-time compatibility engine imported from the
local `codex-desktop-linux` checkout at commit
`f3836c9c225cb0a2868f05bf0bc031f20c57c56f` (2026-07-03). Its MIT license is
preserved at `codex-desktop-linux/LICENSE`.

The import contains tracked source and tests only. It does not contain an
official DMG, extracted application, Electron runtime, build cache, package, or
user profile. Generated paths remain ignored by the imported `.gitignore`.

This copy is intentionally isolated while the Work-specific runtime hardening
and identity changes are developed. Patches should be small, covered by the
imported regression suite, and recorded in the root architecture and validation
documents. Code that exists only to support the old Codex package identity or
its resident updater is not part of the final Work runtime.

