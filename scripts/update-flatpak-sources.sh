#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
generator=${FLATPAK_CARGO_GENERATOR:-}
output="$repo_root/packaging/flatpak/cargo-sources.json"
temporary="$output.new-$$"

if [[ -z $generator || ! -f $generator ]]; then
  printf '%s\n' \
    'Set FLATPAK_CARGO_GENERATOR to a reviewed flatpak-cargo-generator.py checkout.' \
    'The current source list was generated with flatpak/flatpak-builder-tools commit' \
    '737c0085912f9f7dabf9341d4608e2a77a51a73a.' >&2
  exit 2
fi

cleanup() {
  rm -f -- "$temporary"
}
trap cleanup EXIT
python3 "$generator" "$repo_root/Cargo.lock" -o "$temporary"
python3 -m json.tool "$temporary" >/dev/null
mv -f -- "$temporary" "$output"
trap - EXIT
printf 'Updated %s\n' "$output"
