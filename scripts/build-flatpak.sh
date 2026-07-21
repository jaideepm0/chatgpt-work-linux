#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' \
  'build-flatpak: Flatpak product packaging is intentionally disabled.' \
  'The former target packaged the historical Rust/WebKit public-web client, not the ChatGPT.dmg application.' \
  'A Flatpak must not redistribute the proprietary DMG, extracted UI, or generated compatibility build.' >&2
exit 2
