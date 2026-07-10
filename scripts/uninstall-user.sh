#!/usr/bin/env bash
set -euo pipefail

prefix=${CHATGPT_WORK_LINUX_USER_PREFIX:-"$HOME/.local"}
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
rm -f -- \
  "$prefix/bin/chatgpt-work-linux" \
  "$prefix/share/applications/chatgpt-work-linux.desktop" \
  "$prefix/share/applications/io.github.chatgpt_work_linux.desktop" \
  "$prefix/share/icons/hicolor/scalable/apps/chatgpt-work-linux.svg" \
  "$prefix/share/icons/hicolor/scalable/apps/io.github.chatgpt_work_linux.svg" \
  "$prefix/share/icons/hicolor/2048x2048/apps/io.github.chatgpt_work_linux.png" \
  "$prefix/share/metainfo/io.github.chatgpt_work_linux.metainfo.xml"
rm -rf -- "$prefix/opt/chatgpt-work-linux"

if [[ ${1:-} == --purge ]]; then
  rm -rf -- \
    "${XDG_CONFIG_HOME:-$HOME/.config}/chatgpt-work-linux" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/chatgpt-work-linux" \
    "${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux" \
    "${XDG_STATE_HOME:-$HOME/.local/state}/chatgpt-work-linux"
fi

printf 'Uninstalled chatgpt-work-linux%s.\n' "$([[ ${1:-} == --purge ]] && printf ' and profile data' || true)"
