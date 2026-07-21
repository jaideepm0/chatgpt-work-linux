#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d -t chatgpt-work-update-transaction.XXXXXX)
cleanup() {
  chmod -R u+w -- "$temporary" 2>/dev/null || true
  rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'update_transaction: %s\n' "$*" >&2
  exit 1
}

prefix="$temporary/prefix"
snapshot="$repo_root/docs/upstream-snapshot.json"
readarray -t identity < <(python3 - "$snapshot" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(value["application"]["short_version"])
print(value["artifact"]["sha256"])
print(value["artifact"]["size"])
PY
)

make_fixture() {
  local directory=$1 variant=$2
  mkdir -p -- "$directory/.codex-linux"
  cp -- "$repo_root/tests/fixtures/transaction-start.sh" "$directory/start.sh"
  cp -- "$repo_root/tests/fixtures/transaction-binary.sh" "$directory/chatgpt-work-linux-bin"
  chmod 0755 "$directory/start.sh" "$directory/chatgpt-work-linux-bin"
  printf '%s\n' "$variant" >"$directory/variant.txt"
  python3 - "$directory/.codex-linux/build-info.json" "${identity[0]}" "${identity[1]}" "${identity[2]}" <<'PY'
import json
import sys
path, version, digest, size = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"upstreamDmg": {"appVersion": version, "sha256": digest, "sizeBytes": int(size)}}, handle)
    handle.write("\n")
PY
  (
    cd "$directory"
    find . -type f ! -path './.codex-linux/SHA256SUMS' -print0 |
      LC_ALL=C sort -z | xargs -0 sha256sum >.codex-linux/SHA256SUMS
  )
}

build_a="$temporary/build-a"
build_b="$temporary/build-b"
make_fixture "$build_a" A
make_fixture "$build_b" B

install_fixture() {
  local build=$1
  CHATGPT_WORK_BUILD_DIR="$build" CHATGPT_WORK_LINUX_USER_PREFIX="$prefix" \
    "$repo_root/scripts/install-user.sh" >/dev/null
}

install_fixture "$build_a"
base="$prefix/opt/chatgpt-work-linux"
current_a=$(readlink "$base/current")
[[ $current_a == versions/* && -d $base/$current_a ]] || fail 'first install did not publish current'

install_fixture "$build_b"
current_b=$(readlink "$base/current")
previous_b=$(readlink "$base/previous")
[[ $current_b != "$current_a" && $previous_b == "$current_a" ]] || \
  fail 'second install did not retain the previous release'

CHATGPT_WORK_LINUX_USER_PREFIX="$prefix" "$repo_root/scripts/rollback-user.sh" >/dev/null
[[ $(readlink "$base/current") == "$current_a" ]] || fail 'rollback did not restore previous'
[[ $(readlink "$base/previous") == "$current_b" ]] || fail 'rollback did not retain displaced current'

# A failed verification must not touch either release link.
before_current=$(readlink "$base/current")
before_previous=$(readlink "$base/previous")
printf 'tampered\n' >>"$build_b/variant.txt"
if install_fixture "$build_b" >/dev/null 2>&1; then
  fail 'installer accepted a build that differs from its manifest'
fi
[[ $(readlink "$base/current") == "$before_current" ]] || fail 'failed install changed current'
[[ $(readlink "$base/previous") == "$before_previous" ]] || fail 'failed install changed previous'
printf '%s\n' B >"$build_b/variant.txt"

# Prove that direct installers block on the external lock rather than racing
# current/previous publication or pruning.
lock="$prefix/opt/.chatgpt-work-linux.install.lock"
exec {held_lock_fd}>"$lock"
flock "$held_lock_fd"
install_fixture "$build_b" &
blocked_pid=$!
for _ in {1..20}; do
  kill -0 "$blocked_pid" 2>/dev/null || fail 'installer exited while its lock was held'
done
flock -u "$held_lock_fd"
wait "$blocked_pid"

# Hammer alternating publications. Serialization must leave two valid,
# different releases and no dangling managed link.
pids=()
for index in {1..16}; do
  if (( index % 2 )); then
    install_fixture "$build_a" &
  else
    install_fixture "$build_b" &
  fi
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
current=$(readlink "$base/current")
previous=$(readlink "$base/previous")
[[ $current == versions/* && $previous == versions/* && $current != "$previous" ]] || \
  fail 'stress install left invalid release links'
for target in "$current" "$previous"; do
  release="$base/$target"
  [[ -d $release && ! -L $release ]] || fail "managed link is dangling: $target"
  (cd "$release" && sha256sum --check --quiet --strict .codex-linux/SHA256SUMS) || \
    fail "managed release failed integrity verification: $target"
  "$release/start.sh" doctor --json >/dev/null || fail "managed release doctor failed: $target"
done

count=$(find "$base/versions" -mindepth 1 -maxdepth 1 -type d ! -name '.stage-*' | wc -l)
[[ $count -eq 2 ]] || fail "installer retained an unexpected number of releases: $count"

# Cache pruning is explicit/dry-run by default and may never remove the digest
# named by the reviewed snapshot.
prune_cache="$temporary/prune-cache"
mkdir -p -- "$prune_cache/artifacts/${identity[1]}"
for character in a b c; do
  digest=$(printf '%*s' 64 '' | tr ' ' "$character")
  mkdir -p -- "$prune_cache/artifacts/$digest"
  printf '%s\n' "$character" >"$prune_cache/artifacts/$digest/marker"
done
before_prune=$(find "$prune_cache/artifacts" -mindepth 1 -maxdepth 1 -type d | wc -l)
CHATGPT_WORK_CACHE_DIR="$prune_cache" "$repo_root/scripts/prune-upstream-cache.sh" --keep 2 >/dev/null
[[ $(find "$prune_cache/artifacts" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq $before_prune ]] || \
  fail 'cache prune dry-run removed data'
CHATGPT_WORK_CACHE_DIR="$prune_cache" "$repo_root/scripts/prune-upstream-cache.sh" --keep 2 --apply >/dev/null
[[ -d $prune_cache/artifacts/${identity[1]} ]] || fail 'cache prune removed the reviewed artifact'
after_prune=$(find "$prune_cache/artifacts" -mindepth 1 -maxdepth 1 -type d | wc -l)
[[ $after_prune -le 3 ]] || fail "cache prune retained too many artifacts: $after_prune"

# Immutable releases are deliberately read-only. Uninstall must make only its
# verified, user-owned install tree writable and remove it without residue.
CHATGPT_WORK_LINUX_USER_PREFIX="$prefix" "$repo_root/scripts/uninstall-user.sh" >/dev/null
[[ ! -e $base && ! -e $prefix/bin/chatgpt-work-linux ]] || \
  fail 'uninstall left immutable release or launcher residue'
printf 'update_transaction: all tests passed\n'
