#!/usr/bin/env bash
set -euo pipefail

if (( EUID == 0 )); then
  printf 'install-user must run as the desktop user, not root\n' >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
prefix=${CHATGPT_WORK_LINUX_USER_PREFIX:-"$HOME/.local"}
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

base="$prefix/opt/chatgpt-work-linux"
versions="$base/versions"
bin_dir="$prefix/bin"
desktop_dir="$prefix/share/applications"
icon_dir="$prefix/share/icons/hicolor/scalable/apps"
metainfo_dir="$prefix/share/metainfo"

env PATH=/usr/bin:/bin \
  RUSTFLAGS="--remap-path-prefix=$repo_root=/usr/src/chatgpt-work-linux --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/usr/src/cargo --remap-path-prefix=${RUSTUP_HOME:-$HOME/.rustup}=/usr/src/rustup" \
  cargo build \
  --manifest-path "$repo_root/Cargo.toml" \
  --release \
  --locked

binary="$repo_root/target/release/chatgpt-work-linux"
version=$($binary --version | awk '{print $2}')
if [[ ! $version =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]]; then
  printf 'refusing unsafe application version: %q\n' "$version" >&2
  exit 1
fi
digest=$(sha256sum "$binary" | awk '{print $1}')
release_id="$version-$digest"
final="$versions/$release_id"
stage="$versions/.stage-$release_id-$$"

mkdir -p "$versions" "$bin_dir" "$desktop_dir" "$icon_dir" "$metainfo_dir"
chmod 0700 "$base" "$versions"

cleanup_paths=(
  "$stage"
  "$base/.current-new-$$"
  "$base/.previous-new-$$"
  "$bin_dir/.chatgpt-work-linux-new-$$"
  "$desktop_dir/.io.github.chatgpt_work_linux.desktop-new-$$"
  "$icon_dir/.io.github.chatgpt_work_linux.svg-new-$$"
  "$metainfo_dir/.io.github.chatgpt_work_linux.metainfo.xml-new-$$"
)
cleanup() {
  rm -rf -- "${cleanup_paths[@]}"
}
trap cleanup EXIT

verify_release() {
  local release=$1
  [[ -x $release/bin/chatgpt-work-linux && -f $release/SHA256SUMS ]] || return 1
  (
    cd "$release"
    sha256sum --check --quiet --strict SHA256SUMS
  )
  [[ $("$release/bin/chatgpt-work-linux" --version) == "chatgpt-work-linux $version" ]]
}

if [[ ! -e $final ]]; then
  install -Dm755 "$binary" "$stage/bin/chatgpt-work-linux"
  install -Dm755 "$repo_root/scripts/inspect-upstream.py" \
    "$stage/lib/chatgpt-work-linux/inspect-upstream.py"
  install -Dm644 "$repo_root/config.example.toml" \
    "$stage/share/doc/chatgpt-work-linux/config.example.toml"
  install -Dm644 "$repo_root/docs/architecture.md" \
    "$stage/share/doc/chatgpt-work-linux/architecture.md"
  install -Dm644 "$repo_root/docs/audit-and-improvement-plan.md" \
    "$stage/share/doc/chatgpt-work-linux/audit-and-improvement-plan.md"
  install -Dm644 "$repo_root/docs/upstream-snapshot.json" \
    "$stage/share/doc/chatgpt-work-linux/upstream-snapshot.json"
  if [[ -f $repo_root/docs/codex-desktop-linux-review.md ]]; then
    install -Dm644 "$repo_root/docs/codex-desktop-linux-review.md" \
      "$stage/share/doc/chatgpt-work-linux/codex-desktop-linux-review.md"
  fi
  install -Dm644 "$repo_root/docs/validation-report.md" \
    "$stage/share/doc/chatgpt-work-linux/validation-report.md"
  install -Dm644 "$repo_root/packaging/linux/io.github.chatgpt_work_linux.desktop" \
    "$stage/share/applications/io.github.chatgpt_work_linux.desktop"
  install -Dm644 "$repo_root/assets/chatgpt-work-linux.svg" \
    "$stage/share/icons/hicolor/scalable/apps/io.github.chatgpt_work_linux.svg"
  install -Dm644 "$repo_root/packaging/linux/io.github.chatgpt_work_linux.metainfo.xml" \
    "$stage/share/metainfo/io.github.chatgpt_work_linux.metainfo.xml"
  install -Dm644 "$repo_root/LICENSE" "$stage/share/licenses/chatgpt-work-linux/LICENSE"
  (
    cd "$stage"
    find bin lib share -type f -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 sha256sum >SHA256SUMS
  )
  verify_release "$stage"
  mv -- "$stage" "$final"
elif ! verify_release "$final"; then
  printf 'existing immutable release failed verification: %s\n' "$final" >&2
  exit 1
fi

desktop-file-validate "$final/share/applications/io.github.chatgpt_work_linux.desktop"
appstreamcli validate --no-net "$final/share/metainfo/io.github.chatgpt_work_linux.metainfo.xml" >/dev/null

publish_file() {
  local source=$1 target=$2 mode=$3 temporary=$4
  install -m "$mode" "$source" "$temporary"
  mv -Tf -- "$temporary" "$target"
}

# Publish version-independent integration files first. Existing launches still
# resolve through the unchanged current symlink until the final switch below.
publish_file \
  "$final/share/applications/io.github.chatgpt_work_linux.desktop" \
  "$desktop_dir/io.github.chatgpt_work_linux.desktop" 0644 \
  "$desktop_dir/.io.github.chatgpt_work_linux.desktop-new-$$"
rm -f -- "$desktop_dir/chatgpt-work-linux.desktop"
publish_file \
  "$final/share/icons/hicolor/scalable/apps/io.github.chatgpt_work_linux.svg" \
  "$icon_dir/io.github.chatgpt_work_linux.svg" 0644 \
  "$icon_dir/.io.github.chatgpt_work_linux.svg-new-$$"
rm -f -- "$icon_dir/chatgpt-work-linux.svg"
publish_file \
  "$final/share/metainfo/io.github.chatgpt_work_linux.metainfo.xml" \
  "$metainfo_dir/io.github.chatgpt_work_linux.metainfo.xml" 0644 \
  "$metainfo_dir/.io.github.chatgpt_work_linux.metainfo.xml-new-$$"

ln -s "$base/current/bin/chatgpt-work-linux" "$bin_dir/.chatgpt-work-linux-new-$$"
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

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q "$prefix/share/icons/hicolor" >/dev/null 2>&1 || true
fi

active=$(readlink -f "$base/current" 2>/dev/null || true)
previous=$(readlink -f "$base/previous" 2>/dev/null || true)
for candidate in "$versions"/*; do
  [[ -d $candidate && ! -L $candidate ]] || continue
  resolved=$(readlink -f "$candidate" 2>/dev/null || true)
  if [[ -n $resolved && $resolved != "$active" && $resolved != "$previous" ]]; then
    rm -rf -- "$candidate"
  fi
done

trap - EXIT
cleanup
printf 'Installed chatgpt-work-linux %s at %s\n' "$version" "$base/current"
printf 'Launch with: %s\n' "$bin_dir/chatgpt-work-linux"
