#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cache_dir="${CHATGPT_WORK_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux/upstream}"
snapshot=${CHATGPT_WORK_UPSTREAM_SNAPSHOT:-"$repo_root/docs/upstream-snapshot.json"}
keep=2
apply=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --keep) [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || { printf 'invalid --keep value\n' >&2; exit 2; }; keep=$2; shift ;;
    --apply) apply=1 ;;
    -h|--help)
      printf '%s\n' 'Usage: scripts/prune-upstream-cache.sh [--keep N] [--apply]' \
        'Dry-run by default. Retains the reviewed artifact and at least N newest immutable artifacts.'
      exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

artifacts="$cache_dir/artifacts"
[[ -d $artifacts ]] || { printf 'No immutable upstream artifacts to prune.\n'; exit 0; }
mkdir -p -- "$repo_root/.work"
exec {upstream_lock_fd}>"$repo_root/.work/upstream-transaction.lock"
flock "$upstream_lock_fd"

reviewed=$(python3 - "$snapshot" <<'PY'
import json, re, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))["artifact"]["sha256"]
if not re.fullmatch(r"[0-9a-f]{64}", value):
    raise SystemExit("invalid reviewed SHA-256")
print(value)
PY
)

mapfile -t removable < <(python3 - "$artifacts" "$reviewed" "$keep" <<'PY'
from pathlib import Path
import re
import sys

root, reviewed, keep_raw = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
items = []
for path in root.iterdir():
    if path.is_symlink() or not path.is_dir() or not re.fullmatch(r"[0-9a-f]{64}", path.name):
        continue
    items.append((path.stat().st_mtime_ns, path.name))
items.sort(reverse=True)
retained = {name for _, name in items[:keep_raw]}
retained.add(reviewed)
for _, name in items:
    if name not in retained:
        print(name)
PY
)

for digest in "${removable[@]}"; do
  target="$artifacts/$digest"
  [[ $digest =~ ^[0-9a-f]{64}$ && -d $target && ! -L $target ]] || {
    printf 'refusing unsafe cache target: %s\n' "$target" >&2
    exit 1
  }
  find "$target" ! -uid "$EUID" -print -quit | grep -q . && {
    printf 'skipping cache not fully owned by current user: %s\n' "$target" >&2
    continue
  }
  if [[ $apply -eq 1 ]]; then
    chmod -R u+w -- "$target"
    rm -rf -- "$target"
    printf 'Removed immutable upstream cache: %s\n' "$target"
  else
    printf 'Would remove immutable upstream cache: %s\n' "$target"
  fi
done
[[ ${#removable[@]} -gt 0 ]] || printf 'No immutable upstream artifacts are eligible for pruning.\n'
