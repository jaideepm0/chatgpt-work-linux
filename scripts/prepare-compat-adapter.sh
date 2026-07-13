#!/usr/bin/env bash
set -euo pipefail

source_repo=${CHATGPT_WORK_COMPAT_REPO:-"$HOME/programs/codex-desktop-linux"}
remote=${CHATGPT_WORK_COMPAT_REMOTE:-origin}
ref=${CHATGPT_WORK_COMPAT_REF:-"$remote/main"}
cache_root=${CHATGPT_WORK_COMPAT_CACHE:-"${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux/compat"}

fail() {
  printf 'prepare-compat-adapter: %s\n' "$*" >&2
  exit 1
}

[[ -d $source_repo/.git ]] || fail "compatibility checkout is missing: $source_repo"
git -C "$source_repo" diff --quiet || fail "compatibility checkout has unstaged changes"
git -C "$source_repo" diff --cached --quiet || fail "compatibility checkout has staged changes"

if [[ ${CHATGPT_WORK_COMPAT_OFFLINE:-0} != 1 ]]; then
  git -C "$source_repo" fetch --prune "$remote" main >&2
fi

commit=$(git -C "$source_repo" rev-parse --verify "$ref^{commit}")
destination="$cache_root/$commit"
if [[ -x $destination/install.sh && -f $destination/.chatgpt-work-adapter-commit ]] &&
   [[ $(<"$destination/.chatgpt-work-adapter-commit") == "$commit" ]]; then
  printf '%s\n' "$destination"
  exit 0
fi

mkdir -p -- "$cache_root"
chmod 0700 "$cache_root"
exec {cache_lock}>"$cache_root/.archive.lock"
flock "$cache_lock"

# Another builder may have completed this archive while the cache lock was
# being acquired.
if [[ -x $destination/install.sh && -f $destination/.chatgpt-work-adapter-commit ]] &&
   [[ $(<"$destination/.chatgpt-work-adapter-commit") == "$commit" ]]; then
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
mv -- "$stage" "$destination"
trap - EXIT HUP INT TERM
printf '%s\n' "$destination"
