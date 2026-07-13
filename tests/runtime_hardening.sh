#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d -t chatgpt-work-runtime-test.XXXXXX)
cleanup() {
  rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

anchor='process.platform===`linux`&&codexLinuxPrewarmHotkeyWindow()'
printf 'prefix%suffix' "$anchor" >"$temporary/app.asar"
before_size=$(stat -c %s "$temporary/app.asar")
python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/app.asar"
after_size=$(stat -c %s "$temporary/app.asar")
[[ $before_size == "$after_size" ]] || {
  printf 'runtime_hardening: ASAR patch changed byte length\n' >&2
  exit 1
}
! rg -q 'codexLinuxPrewarmHotkeyWindow' "$temporary/app.asar" || {
  printf 'runtime_hardening: startup prewarm call remains\n' >&2
  exit 1
}
if python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/app.asar" >/dev/null 2>&1; then
  printf 'runtime_hardening: patcher accepted an already-patched input\n' >&2
  exit 1
fi

printf '%s%s' "$anchor" "$anchor" >"$temporary/ambiguous.asar"
if python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/ambiguous.asar" >/dev/null 2>&1; then
  printf 'runtime_hardening: patcher accepted an ambiguous input\n' >&2
  exit 1
fi

printf 'runtime_hardening: all tests passed\n'
