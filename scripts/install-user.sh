#!/usr/bin/env bash
set -euo pipefail

(( EUID != 0 )) || { printf 'install-user must run as the desktop user\n' >&2; exit 2; }
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
build=${CHATGPT_WORK_BUILD_DIR:-"$repo_root/.work/chatgpt-work-app"}
prefix=${CHATGPT_WORK_LINUX_USER_PREFIX:-"$HOME/.local"}
[[ $prefix == /* && $prefix != / ]] || { printf 'unsafe user prefix: %s\n' "$prefix" >&2; exit 2; }
case "/$prefix/" in *'/../'*|*'/./'*) printf 'unsafe user prefix: %s\n' "$prefix" >&2; exit 2;; esac

base="$prefix/opt/chatgpt-work-linux"
versions="$base/versions"
bin_dir="$prefix/bin"
desktop_dir="$prefix/share/applications"
icon_dir="$prefix/share/icons/hicolor/2048x2048/apps"
metainfo_dir="$prefix/share/metainfo"
mkdir -p -- "$prefix/opt" "$base" "$versions"
chmod 0700 "$base" "$versions"
exec {install_lock_fd}>"$prefix/opt/.chatgpt-work-linux.install.lock"
flock "$install_lock_fd"

[[ -x $build/start.sh && -x $build/chatgpt-work-linux-bin ]] || {
  printf 'verified Work desktop build is missing; run make build first\n' >&2
  exit 1
}
(cd "$build" && sha256sum --check --quiet --strict .codex-linux/SHA256SUMS)
reviewed_snapshot=${CHATGPT_WORK_UPSTREAM_SNAPSHOT:-"$repo_root/docs/upstream-snapshot.json"}
version=$(python3 - "$build/.codex-linux/build-info.json" "$reviewed_snapshot" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    build_info = json.load(handle)
build = build_info["upstreamDmg"]
with open(sys.argv[2], encoding="utf-8") as handle:
    snapshot = json.load(handle)
expected = snapshot["artifact"]
expected_version = snapshot["application"]["short_version"]
if build.get("fileName") != expected.get("name"):
    raise SystemExit("install-user: build DMG name differs from the reviewed snapshot")
if build.get("appVersion") != expected_version:
    raise SystemExit("install-user: build version differs from the reviewed snapshot")
if build.get("sha256") != expected.get("sha256"):
    raise SystemExit("install-user: build DMG digest differs from the reviewed snapshot")
if int(build.get("sizeBytes", -1)) != int(expected.get("size", -2)):
    raise SystemExit("install-user: build DMG size differs from the reviewed snapshot")
source = build_info.get("source")
if not isinstance(source, dict) or source.get("dirty") is not False:
    raise SystemExit("install-user: build source provenance is dirty or missing")
commit = source.get("commit", "")
if not isinstance(commit, str) or len(commit) != 40 or any(c not in "0123456789abcdef" for c in commit):
    raise SystemExit("install-user: build source commit is invalid")
print(expected_version)
PY
)
[[ $version =~ ^[0-9][0-9A-Za-z._+-]*$ ]] || { printf 'unsafe upstream version: %q\n' "$version" >&2; exit 1; }

digest=$(sha256sum "$build/.codex-linux/SHA256SUMS" | awk '{print $1}')
release_id="$version-$digest"
final="$versions/$release_id"
stage="$versions/.stage-$release_id-$$"

cleanup() {
  [[ ! -e $stage ]] || { chmod -R u+w -- "$stage" 2>/dev/null || true; rm -rf -- "$stage"; }
  rm -f -- "$base/.current-new-$$" "$base/.previous-new-$$" \
    "$bin_dir/.chatgpt-work-linux-new-$$" \
    "$desktop_dir/.io.github.chatgpt_work_linux.desktop-new-$$" \
    "$desktop_dir/.chatgpt-work-linux.desktop-new-$$" \
    "$icon_dir/.io.github.chatgpt_work_linux.png-new-$$" \
    "$metainfo_dir/.io.github.chatgpt_work_linux.metainfo.xml-new-$$"
}
trap cleanup EXIT HUP INT TERM
mkdir -p -- "$bin_dir" "$desktop_dir" "$icon_dir" "$metainfo_dir"
chmod 0700 "$base" "$versions"

verify_release() {
  local release=$1
  [[ -x $release/start.sh && -x $release/chatgpt-work-linux-bin ]] || return 1
  (cd "$release" && sha256sum --check --quiet --strict .codex-linux/SHA256SUMS)
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

# Preserve the existing signed-in Electron identity only after the candidate
# release and its full manifest have passed verification. Test/custom prefixes
# never touch the user's real desktop profile.
if [[ $prefix == "$HOME/.local" && ${CHATGPT_WORK_SKIP_ELECTRON_PROFILE_MIGRATION:-0} != 1 ]]; then
  bash "$repo_root/scripts/migrate-electron-profile.sh"
fi

desktop-file-validate "$repo_root/packaging/linux/io.github.chatgpt_work_linux.desktop"
desktop-file-validate "$repo_root/packaging/linux/chatgpt-work-linux.desktop"
appstreamcli validate --no-net "$repo_root/packaging/linux/io.github.chatgpt_work_linux.metainfo.xml" >/dev/null
publish_file() {
  local source=$1 target=$2 mode=$3 temporary=$4
  install -m "$mode" "$source" "$temporary"
  mv -Tf -- "$temporary" "$target"
}
publish_file "$repo_root/packaging/linux/io.github.chatgpt_work_linux.desktop" \
  "$desktop_dir/io.github.chatgpt_work_linux.desktop" 0644 \
  "$desktop_dir/.io.github.chatgpt_work_linux.desktop-new-$$"
publish_file "$repo_root/packaging/linux/chatgpt-work-linux.desktop" \
  "$desktop_dir/chatgpt-work-linux.desktop" 0644 \
  "$desktop_dir/.chatgpt-work-linux.desktop-new-$$"
publish_file "$repo_root/assets/chatgpt-work-linux.png" \
  "$icon_dir/io.github.chatgpt_work_linux.png" 0644 \
  "$icon_dir/.io.github.chatgpt_work_linux.png-new-$$"
publish_file "$repo_root/packaging/linux/io.github.chatgpt_work_linux.metainfo.xml" \
  "$metainfo_dir/io.github.chatgpt_work_linux.metainfo.xml" 0644 \
  "$metainfo_dir/.io.github.chatgpt_work_linux.metainfo.xml-new-$$"

ln -s "$base/current/start.sh" "$bin_dir/.chatgpt-work-linux-new-$$"
mv -Tf -- "$bin_dir/.chatgpt-work-linux-new-$$" "$bin_dir/chatgpt-work-linux"
old_target=$(readlink "$base/current" 2>/dev/null || true)
[[ -z $old_target || $old_target == versions/* ]] || { printf 'unexpected current link: %s\n' "$old_target" >&2; exit 1; }
if [[ -n $old_target && $old_target != "versions/$release_id" ]]; then
  ln -s "$old_target" "$base/.previous-new-$$"
  mv -Tf -- "$base/.previous-new-$$" "$base/previous"
fi
ln -s "versions/$release_id" "$base/.current-new-$$"
mv -Tf -- "$base/.current-new-$$" "$base/current"

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q "$prefix/share/icons/hicolor" >/dev/null 2>&1 || true
active=$(readlink -f "$base/current" 2>/dev/null || true)
previous=$(readlink -f "$base/previous" 2>/dev/null || true)
for candidate in "$versions"/*; do
  [[ -d $candidate && ! -L $candidate ]] || continue
  resolved=$(readlink -f "$candidate" 2>/dev/null || true)
  [[ -z $resolved || $resolved == "$active" || $resolved == "$previous" ]] && continue
  find "$candidate" ! -uid "$EUID" -print -quit | grep -q . && continue
  chmod -R u+w -- "$candidate"
  rm -rf -- "$candidate"
done

trap - EXIT HUP INT TERM
cleanup
printf 'Installed ChatGPT Work Linux %s at %s\n' "$version" "$base/current"
printf 'Launch with: %s\n' "$bin_dir/chatgpt-work-linux"
