#!/usr/bin/env bash
set -euo pipefail

source_repo=${CHATGPT_WORK_COMPAT_REPO:-"$HOME/programs/codex-desktop-linux"}
remote=${CHATGPT_WORK_COMPAT_REMOTE:-origin}
default_commit=b24e5ff2cfabbd1a366f711229b3b115aa4397fe
ref=${CHATGPT_WORK_COMPAT_REF:-$default_commit}
cache_root=${CHATGPT_WORK_COMPAT_CACHE:-"${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux/compat"}

fail() {
  printf 'prepare-compat-adapter: %s\n' "$*" >&2
  exit 1
}

[[ -d $source_repo/.git ]] || fail "compatibility checkout is missing: $source_repo"
git -C "$source_repo" diff --quiet || fail "compatibility checkout has unstaged changes"
git -C "$source_repo" diff --cached --quiet || fail "compatibility checkout has staged changes"

if ! git -C "$source_repo" rev-parse --verify "$ref^{commit}" >/dev/null 2>&1; then
  [[ ${CHATGPT_WORK_COMPAT_OFFLINE:-0} != 1 ]] || fail "pinned adapter commit is unavailable offline: $ref"
  git -C "$source_repo" fetch --prune "$remote" main >&2
fi

commit=$(git -C "$source_repo" rev-parse --verify "$ref^{commit}")
destination="$cache_root/$commit"

adapter_digest() {
  local directory=$1
  (
    cd "$directory"
    find . -type f ! -path './.chatgpt-work-adapter-integrity' -print0 |
      LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
  )
}

valid_cached_adapter() {
  [[ -x $destination/install.sh &&
     -f $destination/.chatgpt-work-adapter-commit &&
     -f $destination/.chatgpt-work-adapter-integrity ]] || return 1
  [[ $(<"$destination/.chatgpt-work-adapter-commit") == "$commit" ]] || return 1
  [[ $(<"$destination/.chatgpt-work-adapter-integrity") == "$(adapter_digest "$destination")" ]]
}

if [[ -e $destination ]]; then
  valid_cached_adapter || fail "cached adapter failed immutable integrity verification: $destination"
  printf '%s\n' "$destination"
  exit 0
fi

mkdir -p -- "$cache_root"
chmod 0700 "$cache_root"
exec {cache_lock}>"$cache_root/.archive.lock"
flock "$cache_lock"

# Another builder may have completed this archive while the cache lock was
# being acquired.
if [[ -e $destination ]] && valid_cached_adapter; then
  printf '%s\n' "$destination"
  exit 0
fi
[[ ! -e $destination ]] || fail "invalid cached adapter exists: $destination"

stage="$cache_root/.stage-$commit-$$"
cleanup() {
  rm -rf -- "$stage"
}
trap cleanup EXIT HUP INT TERM
mkdir -m 0700 -- "$stage"
git -C "$source_repo" archive --format=tar "$commit" | tar -xf - -C "$stage"
printf '%s\n' "$commit" >"$stage/.chatgpt-work-adapter-commit"
[[ -x $stage/install.sh ]] || fail 'archived adapter has no executable install.sh'
adapter_digest "$stage" >"$stage/.chatgpt-work-adapter-integrity"
mv -- "$stage" "$destination"
trap - EXIT HUP INT TERM
printf '%s\n' "$destination"
