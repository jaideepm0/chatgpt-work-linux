#!/usr/bin/env bash
set -euo pipefail
umask 077

default_remote_url=https://github.com/ilysenko/codex-desktop-linux.git
default_commit=b24e5ff2cfabbd1a366f711229b3b115aa4397fe
default_archive_sha256=4d70d4d738decb0e4bddcd7c167099fdc17038ace8c90af04615edc903d58153
default_tree_sha256=7a98df3cb73ebf1ee8bec43df77fe5a139c107f7dfefa4e9a6ecf0fe7ed83408

source_repo=${CHATGPT_WORK_COMPAT_REPO:-}
source_repo_overridden=${CHATGPT_WORK_COMPAT_REPO+x}
remote_url=$default_remote_url
ref=${CHATGPT_WORK_COMPAT_REF:-$default_commit}
cache_root=${CHATGPT_WORK_COMPAT_CACHE:-"${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux/compat"}
offline=${CHATGPT_WORK_COMPAT_OFFLINE:-0}

fail() {
  printf 'prepare-compat-adapter: %s\n' "$*" >&2
  exit 1
}

[[ $ref =~ ^[0-9a-f]{40}$ ]] || fail 'adapter ref must be an exact lowercase 40-character Git commit'
[[ $offline == 0 || $offline == 1 ]] || fail 'CHATGPT_WORK_COMPAT_OFFLINE must be 0 or 1'
case $remote_url in
  https://*) ;;
  *) fail 'adapter remote must use HTTPS' ;;
esac

if [[ $ref == "$default_commit" ]]; then
  expected_archive_sha256=$default_archive_sha256
else
  expected_archive_sha256=${CHATGPT_WORK_COMPAT_ARCHIVE_SHA256:-}
  [[ $expected_archive_sha256 =~ ^[0-9a-f]{64}$ ]] ||
    fail 'a non-default adapter commit requires CHATGPT_WORK_COMPAT_ARCHIVE_SHA256'
fi

mkdir -p -- "$cache_root"
chmod 0700 "$cache_root"
exec {cache_lock}>"$cache_root/.archive.lock"
flock "$cache_lock"

repository=
if [[ -n $source_repo_overridden ]]; then
  [[ -d $source_repo/.git ]] || fail "compatibility checkout is missing: $source_repo"
  [[ -z $(git -C "$source_repo" status --porcelain=v1 --untracked-files=all) ]] ||
    fail 'compatibility checkout is not clean'
  repository=$source_repo
else
  repository="$cache_root/repository.git"
  if [[ ! -d $repository ]]; then
    [[ $offline == 0 ]] || fail "pinned adapter commit is unavailable offline: $ref"
    git init --bare --quiet "$repository"
    git -C "$repository" remote add origin "$remote_url"
  fi
  configured_remote=$(git -C "$repository" remote get-url origin 2>/dev/null || true)
  [[ $configured_remote == "$remote_url" ]] ||
    fail "cached adapter remote differs from the configured HTTPS remote: $configured_remote"
fi

if ! git -C "$repository" cat-file -e "$ref^{commit}" 2>/dev/null; then
  [[ $offline == 0 ]] || fail "pinned adapter commit is unavailable offline: $ref"
  git -C "$repository" fetch --no-tags --depth=1 origin "$ref" >&2
fi
commit=$(git -C "$repository" rev-parse --verify "$ref^{commit}")
[[ $commit == "$ref" ]] || fail "adapter ref resolved to unexpected commit: $commit"
destination="$cache_root/$commit"

adapter_digest() {
  python3 - "$1" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
digest = hashlib.sha256()
excluded = {
    ".chatgpt-work-adapter-integrity",
    ".chatgpt-work-adapter-archive-sha256",
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
        raise SystemExit(f"unsupported adapter entry: {path}")
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

valid_cached_adapter() {
  local actual_digest
  [[ -x $destination/install.sh &&
     -f $destination/.chatgpt-work-adapter-commit &&
     -f $destination/.chatgpt-work-adapter-integrity ]] || return 1
  [[ $(<"$destination/.chatgpt-work-adapter-commit") == "$commit" ]] || return 1
  actual_digest=$(adapter_digest "$destination")
  [[ $(<"$destination/.chatgpt-work-adapter-integrity") == "$actual_digest" ]] || return 1
  [[ ! -f $destination/.chatgpt-work-adapter-archive-sha256 ||
     $(<"$destination/.chatgpt-work-adapter-archive-sha256") == "$expected_archive_sha256" ]]
}

if [[ -e $destination ]]; then
  if valid_cached_adapter; then
    printf '%s\n' "$destination"
    exit 0
  fi
  # Upgrade only the old default cache marker after comparing the entire tree
  # with the source-controlled strong digest. Never repair arbitrary content.
  if [[ $commit == "$default_commit" && -d $destination && ! -L $destination &&
        $(adapter_digest "$destination") == "$default_tree_sha256" ]]; then
    printf '%s\n' "$default_tree_sha256" >"$destination/.chatgpt-work-adapter-integrity.new"
    mv -f -- "$destination/.chatgpt-work-adapter-integrity.new" \
      "$destination/.chatgpt-work-adapter-integrity"
    printf '%s\n' "$expected_archive_sha256" >"$destination/.chatgpt-work-adapter-archive-sha256.new"
    mv -f -- "$destination/.chatgpt-work-adapter-archive-sha256.new" \
      "$destination/.chatgpt-work-adapter-archive-sha256"
    valid_cached_adapter || fail "upgraded adapter cache failed verification: $destination"
    printf '%s\n' "$destination"
    exit 0
  fi
  fail "cached adapter failed immutable integrity verification: $destination"
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
  fail "adapter archive SHA-256 differs from the reviewed value: $actual_archive_sha256"
tar -xf "$archive" -C "$stage"
printf '%s\n' "$commit" >"$stage/.chatgpt-work-adapter-commit"
printf '%s\n' "$expected_archive_sha256" >"$stage/.chatgpt-work-adapter-archive-sha256"
[[ -x $stage/install.sh ]] || fail 'archived adapter has no executable install.sh'
adapter_digest "$stage" >"$stage/.chatgpt-work-adapter-integrity"
mv -- "$stage" "$destination"
rm -f -- "$archive"
trap - EXIT HUP INT TERM
printf '%s\n' "$destination"
