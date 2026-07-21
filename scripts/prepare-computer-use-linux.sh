#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
default_commit=6d0b477d0bf92763184be33ae4fc9b5b9efacddf
default_archive_sha256=e80a3443e380e97bf8bccdafb435d87361fd069bb83c4aa6a3fa49212663cf95
default_tree_sha256=da8bea49dcc1e8377491016b3dbd07f757139878091e62164fcc98958e2406b3

source_repo=${CHATGPT_WORK_COMPUTER_USE_REPO:-"$repo_root/../computer-use-linux"}
ref=${CHATGPT_WORK_COMPUTER_USE_REF:-$default_commit}
cache_root=${CHATGPT_WORK_COMPUTER_USE_CACHE:-"${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux/computer-use"}

fail() {
  printf 'prepare-computer-use-linux: %s\n' "$*" >&2
  exit 1
}

[[ $ref =~ ^[0-9a-f]{40}$ ]] || fail 'source ref must be an exact lowercase 40-character Git commit'

if [[ $ref == "$default_commit" ]]; then
  expected_archive_sha256=$default_archive_sha256
  expected_tree_sha256=$default_tree_sha256
else
  expected_archive_sha256=${CHATGPT_WORK_COMPUTER_USE_ARCHIVE_SHA256:-}
  expected_tree_sha256=${CHATGPT_WORK_COMPUTER_USE_TREE_SHA256:-}
  [[ $expected_archive_sha256 =~ ^[0-9a-f]{64}$ ]] ||
    fail 'a non-default source commit requires CHATGPT_WORK_COMPUTER_USE_ARCHIVE_SHA256'
  [[ $expected_tree_sha256 =~ ^[0-9a-f]{64}$ ]] ||
    fail 'a non-default source commit requires CHATGPT_WORK_COMPUTER_USE_TREE_SHA256'
fi

mkdir -p -- "$cache_root"
chmod 0700 "$cache_root"
exec {cache_lock}>"$cache_root/.archive.lock"
flock "$cache_lock"

[[ -d $source_repo/.git ]] || fail "private source checkout is missing: $source_repo"
[[ -z $(git -C "$source_repo" status --porcelain=v1 --untracked-files=all) ]] ||
  fail 'private source checkout is not clean'
repository=$(cd -- "$source_repo" && pwd -P)
git -C "$repository" cat-file -e "$ref^{commit}" 2>/dev/null ||
  fail "pinned source commit is unavailable in the private checkout: $ref"
commit=$(git -C "$repository" rev-parse --verify "$ref^{commit}")
[[ $commit == "$ref" ]] || fail "source ref resolved to unexpected commit: $commit"
destination="$cache_root/$commit"

source_digest() {
  python3 - "$1" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
digest = hashlib.sha256()
excluded = {
    ".chatgpt-work-computer-use-archive-sha256",
    ".chatgpt-work-computer-use-commit",
    ".chatgpt-work-computer-use-integrity",
}
for path in sorted(root.rglob("*"), key=lambda item: os.fsencode(item.relative_to(root))):
    relative = path.relative_to(root)
    if relative.as_posix() in excluded:
        continue
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    if path.is_symlink():
        kind = b"l"
    elif path.is_dir():
        kind = b"d"
    elif path.is_file():
        kind = b"f"
    else:
        raise SystemExit(f"unsupported Computer Use source entry: {path}")
    digest.update(kind + b"\0" + f"{mode:o}".encode() + b"\0")
    digest.update(os.fsencode(relative) + b"\0")
    if kind == b"l":
        digest.update(os.fsencode(os.readlink(path)) + b"\0")
    elif kind == b"f":
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
print(digest.hexdigest())
PY
}

valid_cached_source() {
  local actual_digest
  [[ -f $destination/Cargo.toml &&
     -f $destination/Cargo.lock &&
     -f $destination/LICENSE &&
     -f $destination/src/server.rs &&
     -f $destination/src/bin/codex-chrome-extension-host.rs &&
     -f $destination/.chatgpt-work-computer-use-commit &&
     -f $destination/.chatgpt-work-computer-use-archive-sha256 &&
     -f $destination/.chatgpt-work-computer-use-integrity ]] || return 1
  [[ $(<"$destination/.chatgpt-work-computer-use-commit") == "$commit" ]] || return 1
  [[ $(<"$destination/.chatgpt-work-computer-use-archive-sha256") == "$expected_archive_sha256" ]] || return 1
  actual_digest=$(source_digest "$destination")
  [[ $actual_digest == "$expected_tree_sha256" ]] || return 1
  [[ $(<"$destination/.chatgpt-work-computer-use-integrity") == "$actual_digest" ]]
}

if [[ -e $destination ]]; then
  valid_cached_source || fail "cached source failed immutable integrity verification: $destination"
  printf '%s\n' "$destination"
  exit 0
fi

stage="$cache_root/.stage-$commit-$$"
archive="$cache_root/.archive-$commit-$$.tar"
cleanup() {
  rm -rf -- "$stage"
  rm -f -- "$archive"
}
trap cleanup EXIT HUP INT TERM
mkdir -m 0700 -- "$stage"
git -C "$repository" archive --format=tar "$commit" >"$archive"
actual_archive_sha256=$(sha256sum "$archive" | awk '{print $1}')
[[ $actual_archive_sha256 == "$expected_archive_sha256" ]] ||
  fail "source archive SHA-256 differs from the reviewed value: $actual_archive_sha256"
tar -xf "$archive" -C "$stage"
actual_tree_sha256=$(source_digest "$stage")
[[ $actual_tree_sha256 == "$expected_tree_sha256" ]] ||
  fail "extracted source SHA-256 differs from the reviewed value: $actual_tree_sha256"
printf '%s\n' "$commit" >"$stage/.chatgpt-work-computer-use-commit"
printf '%s\n' "$expected_archive_sha256" >"$stage/.chatgpt-work-computer-use-archive-sha256"
printf '%s\n' "$actual_tree_sha256" >"$stage/.chatgpt-work-computer-use-integrity"
mv -- "$stage" "$destination"
rm -f -- "$archive"
trap - EXIT HUP INT TERM
printf '%s\n' "$destination"
