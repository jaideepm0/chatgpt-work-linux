#!/usr/bin/env bash
set -euo pipefail

if (( EUID == 0 )); then
  printf 'install-user must run as the desktop user, not root\n' >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
build=${CHATGPT_WORK_BUILD_DIR:-"$repo_root/.work/chatgpt-work-app"}
prefix=${CHATGPT_WORK_LINUX_USER_PREFIX:-"$HOME/.local"}
case $prefix in
  /*) ;;
  *) printf 'CHATGPT_WORK_LINUX_USER_PREFIX must be absolute\n' >&2; exit 2 ;;
esac
case "/$prefix/" in
  *'/../'*|*'/./'*) printf 'user prefix contains an unsafe path component\n' >&2; exit 2 ;;
esac
[[ $prefix != / ]] || { printf 'refusing the filesystem root as a prefix\n' >&2; exit 2; }

[[ -x $build/start.sh && -x $build/chatgpt-work-linux-bin ]] || {
  printf 'verified Work build is missing; run make build first\n' >&2
  exit 1
}
(
  cd "$build"
  sha256sum --check --quiet --strict .codex-linux/SHA256SUMS
)

base="$prefix/opt/chatgpt-work-linux"
versions="$base/versions"
bin_dir="$prefix/bin"
desktop_dir="$prefix/share/applications"
icon_dir="$prefix/share/icons/hicolor/2048x2048/apps"
metainfo_dir="$prefix/share/metainfo"
manifest_digest=$(sha256sum "$build/.codex-linux/SHA256SUMS" | awk '{print substr($1,1,16)}')
release_id="26.707.31428-$manifest_digest"
final="$versions/$release_id"
stage="$versions/.stage-$release_id-$$"

cleanup() {
  if [[ -e $stage ]]; then
    chmod -R u+w -- "$stage" 2>/dev/null || true
    rm -rf -- "$stage"
  fi
  rm -f -- "$base/.current-new-$$" "$base/.previous-new-$$" \
    "$bin_dir/.chatgpt-work-linux-new-$$" \
    "$desktop_dir/.io.github.chatgpt_work_linux.desktop-new-$$" \
    "$icon_dir/.io.github.chatgpt_work_linux.png-new-$$" \
    "$metainfo_dir/.io.github.chatgpt_work_linux.metainfo.xml-new-$$"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$versions" "$bin_dir" "$desktop_dir" "$icon_dir" "$metainfo_dir"
chmod 0700 "$base" "$versions"

verify_release() {
  local release=$1
  [[ -x $release/start.sh && -x $release/chatgpt-work-linux-bin ]] || return 1
  (
    cd "$release"
    sha256sum --check --quiet --strict .codex-linux/SHA256SUMS
  )
  "$release/start.sh" doctor --json >/dev/null
}

if [[ ! -e $final ]]; then
  mkdir -m 0700 "$stage"
  cp -a --reflink=auto "$build/." "$stage/"
  verify_release "$stage"
  chmod -R a-w "$stage"
  mv -- "$stage" "$final"
elif ! verify_release "$final"; then
  printf 'existing immutable release failed verification: %s\n' "$final" >&2
  exit 1
fi

desktop-file-validate "$repo_root/packaging/linux/io.github.chatgpt_work_linux.desktop"
appstreamcli validate --no-net "$repo_root/packaging/linux/io.github.chatgpt_work_linux.metainfo.xml" >/dev/null

publish_file() {
  local source=$1 target=$2 mode=$3 temporary=$4
  install -m "$mode" "$source" "$temporary"
  mv -Tf -- "$temporary" "$target"
}

publish_file "$repo_root/packaging/linux/io.github.chatgpt_work_linux.desktop" \
  "$desktop_dir/io.github.chatgpt_work_linux.desktop" 0644 \
  "$desktop_dir/.io.github.chatgpt_work_linux.desktop-new-$$"
publish_file "$repo_root/assets/chatgpt-work-linux.png" \
  "$icon_dir/io.github.chatgpt_work_linux.png" 0644 \
  "$icon_dir/.io.github.chatgpt_work_linux.png-new-$$"
rm -f -- \
  "$prefix/share/icons/hicolor/scalable/apps/io.github.chatgpt_work_linux.svg" \
  "$prefix/share/icons/hicolor/scalable/apps/chatgpt-work-linux.svg"
publish_file "$repo_root/packaging/linux/io.github.chatgpt_work_linux.metainfo.xml" \
  "$metainfo_dir/io.github.chatgpt_work_linux.metainfo.xml" 0644 \
  "$metainfo_dir/.io.github.chatgpt_work_linux.metainfo.xml-new-$$"

ln -s "$base/current/start.sh" "$bin_dir/.chatgpt-work-linux-new-$$"
mv -Tf -- "$bin_dir/.chatgpt-work-linux-new-$$" "$bin_dir/chatgpt-work-linux"

old_target=$(readlink "$base/current" 2>/dev/null || true)
if [[ -n $old_target && $old_target != versions/* ]]; then
  printf 'refusing unexpected current release link: %s\n' "$old_target" >&2
  exit 1
fi
if [[ -n $old_target && $old_target != "versions/$release_id" ]]; then
  ln -s "$old_target" "$base/.previous-new-$$"
  mv -Tf -- "$base/.previous-new-$$" "$base/previous"
fi
ln -s "versions/$release_id" "$base/.current-new-$$"
mv -Tf -- "$base/.current-new-$$" "$base/current"

command -v update-desktop-database >/dev/null 2>&1 &&
  update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
command -v gtk-update-icon-cache >/dev/null 2>&1 &&
  gtk-update-icon-cache -q "$prefix/share/icons/hicolor" >/dev/null 2>&1 || true

active=$(readlink -f "$base/current" 2>/dev/null || true)
previous=$(readlink -f "$base/previous" 2>/dev/null || true)
for candidate in "$versions"/*; do
  [[ -d $candidate && ! -L $candidate ]] || continue
  resolved=$(readlink -f "$candidate" 2>/dev/null || true)
  if [[ -n $resolved && $resolved != "$active" && $resolved != "$previous" ]]; then
    chmod -R u+w -- "$candidate"
    rm -rf -- "$candidate"
  fi
done

trap - EXIT
cleanup
printf 'Installed ChatGPT Work Linux (unofficial) at %s\n' "$base/current"
printf 'Launch with: %s\n' "$bin_dir/chatgpt-work-linux"
