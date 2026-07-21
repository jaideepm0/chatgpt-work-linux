#!/usr/bin/env bash
set -euo pipefail
umask 077

(( EUID != 0 )) || { printf 'rollback-user must run as the desktop user\n' >&2; exit 2; }
prefix=${CHATGPT_WORK_LINUX_USER_PREFIX:-"$HOME/.local"}
[[ $prefix == /* && $prefix != / ]] || { printf 'unsafe user prefix: %s\n' "$prefix" >&2; exit 2; }
case "/$prefix/" in *'/../'*|*'/./'*) printf 'unsafe user prefix: %s\n' "$prefix" >&2; exit 2;; esac

base="$prefix/opt/chatgpt-work-linux"
[[ -d $base/versions ]] || { printf 'no installed releases exist under %s\n' "$base" >&2; exit 1; }
exec {install_lock_fd}>"$prefix/opt/.chatgpt-work-linux.install.lock"
flock "$install_lock_fd"

current_target=$(readlink "$base/current" 2>/dev/null || true)
previous_target=$(readlink "$base/previous" 2>/dev/null || true)
[[ $current_target == versions/* && $previous_target == versions/* ]] || {
  printf 'both current and previous must be valid managed release links\n' >&2
  exit 1
}
[[ $current_target != "$previous_target" ]] || { printf 'current and previous are identical\n' >&2; exit 1; }
current="$base/$current_target"
previous="$base/$previous_target"
[[ -d $current && ! -L $current && -d $previous && ! -L $previous ]] || {
  printf 'rollback release directory is missing or unsafe\n' >&2
  exit 1
}

verify_release() {
  local release=$1
  [[ -x $release/start.sh && -x $release/chatgpt-work-linux-bin ]] || return 1
  (cd "$release" && sha256sum --check --quiet --strict .codex-linux/SHA256SUMS)
  "$release/start.sh" doctor --json >/dev/null
}
verify_release "$current" || { printf 'current release failed verification\n' >&2; exit 1; }
verify_release "$previous" || { printf 'previous release failed verification\n' >&2; exit 1; }

current_new="$base/.current-rollback-$$"
previous_new="$base/.previous-rollback-$$"
cleanup() { rm -f -- "$current_new" "$previous_new"; }
trap cleanup EXIT HUP INT TERM
ln -s "$previous_target" "$current_new"
ln -s "$current_target" "$previous_new"
# Switch current first: interruption can only leave a verified release active.
mv -Tf -- "$current_new" "$base/current"
mv -Tf -- "$previous_new" "$base/previous"
trap - EXIT HUP INT TERM
printf 'Rolled back current from %s to %s.\n' "${current_target#versions/}" "${previous_target#versions/}"
