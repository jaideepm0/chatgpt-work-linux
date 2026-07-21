#!/usr/bin/env bash
set -euo pipefail

prefix=${CHATGPT_WORK_LINUX_USER_PREFIX:-"$HOME/.local"}
case ${1:-} in
  ''|--purge) ;;
  *) printf 'usage: scripts/uninstall-user.sh [--purge]\n' >&2; exit 2 ;;
esac
if (( EUID == 0 )); then
  printf 'uninstall-user must run as the desktop user, not root\n' >&2
  exit 2
fi
case $prefix in
  /*) ;;
  *)
    printf 'CHATGPT_WORK_LINUX_USER_PREFIX must be absolute\n' >&2
    exit 2
    ;;
esac
case "/$prefix/" in
  *'/../'*|*'/./'*)
    printf 'CHATGPT_WORK_LINUX_USER_PREFIX must not contain dot path components\n' >&2
    exit 2
    ;;
esac
if [[ $prefix == / ]]; then
  printf 'refusing to use the filesystem root as a user prefix\n' >&2
  exit 2
fi
mkdir -p -- "$prefix/opt"
exec {install_lock_fd}>"$prefix/opt/.chatgpt-work-linux.install.lock"
flock "$install_lock_fd"
remove_owned_tree() {
  local target=$1 label=$2
  [[ -e $target || -L $target ]] || return 0
  if [[ -L $target ]]; then
    rm -f -- "$target"
    return 0
  fi
  [[ -d $target && $target == /* && $target != / ]] || {
    printf 'refusing unsafe %s tree: %s\n' "$label" "$target" >&2
    return 1
  }
  if find "$target" -xdev ! -uid "$EUID" -print -quit | grep -q .; then
    printf 'refusing %s tree containing files owned by another user: %s\n' \
      "$label" "$target" >&2
    return 1
  fi
  chmod -R u+w -- "$target"
  rm -rf -- "$target"
  [[ ! -e $target ]] || {
    printf 'could not fully remove %s tree: %s\n' "$label" "$target" >&2
    return 1
  }
}

remove_owned_tree "$prefix/opt/chatgpt-work-linux" 'immutable install'
rm -f -- \
  "$prefix/bin/chatgpt-work-linux" \
  "$prefix/share/applications/chatgpt-work-linux.desktop" \
  "$prefix/share/applications/io.github.chatgpt_work_linux.desktop" \
  "$prefix/share/icons/hicolor/scalable/apps/chatgpt-work-linux.svg" \
  "$prefix/share/icons/hicolor/scalable/apps/io.github.chatgpt_work_linux.svg" \
  "$prefix/share/icons/hicolor/2048x2048/apps/io.github.chatgpt_work_linux.png" \
  "$prefix/share/metainfo/io.github.chatgpt_work_linux.metainfo.xml"

if [[ ${1:-} == --purge ]]; then
  remove_owned_tree "${XDG_CONFIG_HOME:-$HOME/.config}/chatgpt-work-linux" 'configuration profile'
  remove_owned_tree "${XDG_DATA_HOME:-$HOME/.local/share}/chatgpt-work-linux" 'data profile'
  remove_owned_tree "${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux" 'cache profile'
  remove_owned_tree "${XDG_STATE_HOME:-$HOME/.local/state}/chatgpt-work-linux" 'state profile'
fi

printf 'Uninstalled chatgpt-work-linux%s.\n' "$([[ ${1:-} == --purge ]] && printf ' and profile data' || true)"
