#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cache_dir="${CHATGPT_WORK_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux/upstream}"
prefix=${CHATGPT_WORK_LINUX_USER_PREFIX:-"$HOME/.local"}
release_gates=0
skip_remote_check=0
allow_memory_pressure=0

usage() {
  cat <<'EOF'
Usage: scripts/update-user.sh [--release-gates] [--allow-memory-pressure] [--skip-remote-check]

Build and install only the exact reviewed upstream snapshot. This command never
promotes a newly published DMG. Use refresh-upstream-snapshot.sh to acquire and
explicitly approve a candidate first.

  --release-gates       also run normal and constrained runtime profiles
  --allow-memory-pressure
                        consent to the constrained profile's kernel OOM stress
  --skip-remote-check   do not perform the rate-limited metadata-only HEAD check
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --release-gates) release_gates=1 ;;
    --allow-memory-pressure) allow_memory_pressure=1 ;;
    --skip-remote-check) skip_remote_check=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'update-user: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [[ $allow_memory_pressure -eq 1 && $release_gates -ne 1 ]]; then
  printf 'update-user: --allow-memory-pressure requires --release-gates\n' >&2
  exit 2
fi
if [[ $release_gates -eq 1 && $allow_memory_pressure -ne 1 ]]; then
  printf '%s\n' \
    'update-user: release gates include a kernel OOM stress test.' \
    'Re-run with --allow-memory-pressure only after saving other desktop work.' >&2
  exit 2
fi

(( EUID != 0 )) || { printf 'update-user must run as the desktop user\n' >&2; exit 2; }
[[ $prefix == /* && $prefix != / ]] || { printf 'unsafe user prefix: %s\n' "$prefix" >&2; exit 2; }

mkdir -p -- "$repo_root/.work" "$cache_dir"
exec {upstream_lock_fd}>"$repo_root/.work/upstream-transaction.lock"
flock "$upstream_lock_fd"
export CHATGPT_WORK_UPSTREAM_LOCK_HELD=1

if [[ $skip_remote_check -eq 0 ]]; then
  check_json=$("$repo_root/scripts/check-upstream.sh" --json)
  status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$check_json")
  if [[ $status == update-available ]]; then
    printf '%s\n' \
      'A different upstream artifact is available. It was not trusted or installed.' \
      'Run make refresh-upstream, review the candidate, then promote it with its exact version and SHA-256.' >&2
  fi
fi

printf 'Running repository and drift checks...\n'
make -C "$repo_root" check
printf 'Building the exact reviewed compatibility transaction...\n'
make -C "$repo_root" build
make -C "$repo_root" doctor
make -C "$repo_root" smoke-wayland
if [[ $release_gates -eq 1 ]]; then
  make -C "$repo_root" profile-runtime
  CHATGPT_WORK_PROFILE_ALLOW_MEMORY_PRESSURE=1 \
    make -C "$repo_root" profile-runtime-constrained
fi
printf 'Publishing the immutable user release...\n'
make -C "$repo_root" install-user

installed="$prefix/bin/chatgpt-work-linux"
[[ -x $installed ]] || { printf 'installed launcher is missing: %s\n' "$installed" >&2; exit 1; }
"$installed" doctor --json >/dev/null
"$installed" computer-use-doctor >/dev/null
printf 'Update completed from the reviewed snapshot. Reopen a running app to use the new release.\n'
