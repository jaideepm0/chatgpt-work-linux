#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
preparer="$repo_root/scripts/prepare-computer-use-linux.sh"
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM
source_repo="$temporary/source"
cache="$temporary/cache"
extracted="$temporary/extracted"

git init --quiet "$source_repo"
git -C "$source_repo" config user.name fixture
git -C "$source_repo" config user.email fixture@example.invalid
mkdir -p -- "$source_repo/src/bin" "$extracted"
printf '[package]\nname="fixture"\nversion="0.0.0"\n' >"$source_repo/Cargo.toml"
printf '# fixture lock\n' >"$source_repo/Cargo.lock"
printf 'fixture license\n' >"$source_repo/LICENSE"
printf 'fn fixture() {}\n' >"$source_repo/src/server.rs"
printf 'fn main() {}\n' >"$source_repo/src/bin/codex-chrome-extension-host.rs"
git -C "$source_repo" add .
git -C "$source_repo" commit --quiet -m fixture
ref=$(git -C "$source_repo" rev-parse HEAD)
archive="$temporary/source.tar"
git -C "$source_repo" archive --format=tar "$ref" >"$archive"
archive_sha256=$(sha256sum "$archive" | awk '{print $1}')
(umask 077; tar -xf "$archive" -C "$extracted")

tree_sha256=$(python3 - "$extracted" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(root.rglob("*"), key=lambda item: os.fsencode(item.relative_to(root))):
    relative = path.relative_to(root)
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    if path.is_symlink():
        kind = b"l"
    elif path.is_dir():
        kind = b"d"
    elif path.is_file():
        kind = b"f"
    else:
        raise SystemExit(f"unsupported fixture entry: {path}")
    digest.update(kind + b"\0" + f"{mode:o}".encode() + b"\0")
    digest.update(os.fsencode(relative) + b"\0")
    if kind == b"l":
        digest.update(os.fsencode(os.readlink(path)) + b"\0")
    elif kind == b"f":
        digest.update(path.read_bytes())
print(digest.hexdigest())
PY
)

run_preparer() {
  CHATGPT_WORK_COMPUTER_USE_REPO="$source_repo" \
  CHATGPT_WORK_COMPUTER_USE_REF="$ref" \
  CHATGPT_WORK_COMPUTER_USE_ARCHIVE_SHA256="$archive_sha256" \
  CHATGPT_WORK_COMPUTER_USE_TREE_SHA256="$tree_sha256" \
  CHATGPT_WORK_COMPUTER_USE_CACHE="${TEST_CACHE:-$cache}" \
    "$preparer"
}

first=$(run_preparer)
second=$(run_preparer)
[[ $first == "$second" && -f $first/src/server.rs ]] || {
  printf 'computer_use_source: immutable cache was not reused\n' >&2
  exit 1
}

printf 'tampered\n' >>"$first/src/server.rs"
if run_preparer >/dev/null 2>&1; then
  printf 'computer_use_source: tampered cache was accepted\n' >&2
  exit 1
fi

printf 'dirty\n' >"$source_repo/untracked"
if TEST_CACHE="$temporary/dirty-cache" run_preparer >/dev/null 2>&1; then
  printf 'computer_use_source: dirty private checkout was accepted\n' >&2
  exit 1
fi

printf 'computer_use_source: all tests passed\n'
