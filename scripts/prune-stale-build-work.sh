#!/usr/bin/env bash
set -euo pipefail

(( $# >= 2 )) || {
  printf 'usage: prune-stale-build-work.sh ROOT PREFIX...\n' >&2
  exit 2
}

root=$(realpath -m -- "$1")
shift
[[ $root == /* && $root != / && -d $root && ! -L $root ]] || {
  printf 'prune-stale-build-work: unsafe root: %s\n' "$root" >&2
  exit 2
}

for prefix in "$@"; do
  [[ $prefix =~ ^\.(adapter|stage)-[A-Za-z0-9._-]+-$ ]] || {
    printf 'prune-stale-build-work: unsafe prefix: %s\n' "$prefix" >&2
    exit 2
  }
  for candidate in "$root/$prefix"*; do
    [[ -d $candidate && ! -L $candidate ]] || continue
    [[ $(dirname -- "$candidate") == "$root" ]] || continue
    name=$(basename -- "$candidate")
    pid=${name#"$prefix"}
    [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
    [[ ! -e /proc/$pid ]] || continue
    if find "$candidate" -xdev ! -uid "$EUID" -print -quit | grep -q .; then
      printf 'prune-stale-build-work: retaining tree with foreign ownership: %s\n' \
        "$candidate" >&2
      continue
    fi
    chmod -R u+w -- "$candidate"
    rm -rf -- "$candidate"
  done
done
