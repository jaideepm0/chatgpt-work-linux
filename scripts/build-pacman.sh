#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' \
  'build-pacman: native binary packaging is intentionally disabled.' \
  'The former target packaged the historical Rust/WebKit public-web client, not the ChatGPT.dmg application.' \
  'Ship only source tooling; each user must build the exact reviewed ChatGPT.dmg locally with make update-user.' >&2
exit 2
