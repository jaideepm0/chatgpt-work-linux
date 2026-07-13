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
  *) printf 'CHATGPT_WORK_LINUX_USER_PREFIX must be absolute\n' >&2; exit 2 ;;
esac
case "/$prefix/" in
  *'/../'*|*'/./'*) printf 'user prefix contains an unsafe path component\n' >&2; exit 2 ;;
esac
[[ $prefix != / ]] || { printf 'refusing the filesystem root as a prefix\n' >&2; exit 2; }

base="$prefix/opt/chatgpt-work-linux"
versions="$base/versions"
bin_dir="$prefix/bin"
desktop_dir="$prefix/share/applications"
icon_dir="$prefix/share/icons/hicolor/2048x2048/apps"
metainfo_dir="$prefix/share/metainfo"

env PATH=/usr/bin:/bin \
  RUSTFLAGS="--remap-path-prefix=$repo_root=/usr/src/chatgpt-work-linux --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/usr/src/cargo --remap-path-prefix=${RUSTUP_HOME:-$HOME/.rustup}=/usr/src/rustup" \
  cargo build --manifest-path "$repo_root/Cargo.toml" --release --locked

binary="$repo_root/target/release/chatgpt-work-linux"
sbom="$repo_root/chatgpt-work-linux.cdx.json"
rm -f -- "$sbom"
if ! cargo cyclonedx --version >/dev/null 2>&1; then
  printf 'install-user requires the cargo-cyclonedx build tool\n' >&2
  exit 2
fi
SOURCE_DATE_EPOCH=0 CARGO_NET_OFFLINE=true cargo cyclonedx \
  --manifest-path "$repo_root/Cargo.toml" --format json --spec-version 1.5 \
  --override-filename chatgpt-work-linux.cdx --all \
  --target x86_64-unknown-linux-gnu --quiet
bash "$repo_root/scripts/normalize-sbom.sh" "$sbom" "$repo_root"

version=$($binary --version | awk '{print $2}')
[[ $version =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] || {
  printf 'refusing unsafe application version: %q\n' "$version" >&2
  exit 1
}

release_sources=(
  "$binary"
  "$repo_root/scripts/inspect-upstream.py"
  "$repo_root/config.example.toml"
  "$repo_root/docs/architecture.md"
  "$repo_root/docs/audit-and-improvement-plan.md"
  "$repo_root/docs/upstream-feature-audit.md"
  "$repo_root/docs/work-upstream-assessment.md"
  "$repo_root/docs/upstream-snapshot.json"
  "$repo_root/docs/codex-desktop-linux-review.md"
  "$repo_root/docs/validation-report.md"
  "$repo_root/assets/ICON-PROVENANCE.md"
  "$repo_root/assets/chatgpt-work-linux.png"
  "$repo_root/packaging/linux/io.github.chatgpt_work_linux.desktop"
  "$repo_root/packaging/linux/io.github.chatgpt_work_linux.metainfo.xml"
  "$repo_root/LICENSE"
  "$sbom"
)
digest=$(for source in "${release_sources[@]}"; do sha256sum "$source" | awk '{print $1}'; done | sha256sum | awk '{print $1}')
release_id="$version-$digest"
final="$versions/$release_id"
stage="$versions/.stage-$release_id-$$"

cleanup() {
  rm -f -- "$sbom" "$base/.current-new-$$" "$base/.previous-new-$$" \
    "$bin_dir/.chatgpt-work-linux-new-$$" \
    "$desktop_dir/.io.github.chatgpt_work_linux.desktop-new-$$" \
    "$icon_dir/.io.github.chatgpt_work_linux.png-new-$$" \
    "$metainfo_dir/.io.github.chatgpt_work_linux.metainfo.xml-new-$$"
  rm -rf -- "$stage"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$versions" "$bin_dir" "$desktop_dir" "$icon_dir" "$metainfo_dir"
chmod 0700 "$base" "$versions"

verify_release() {
  local release=$1
  [[ -x $release/bin/chatgpt-work-linux && -f $release/SHA256SUMS ]] || return 1
  (cd "$release" && sha256sum --check --quiet --strict SHA256SUMS)
  [[ $("$release/bin/chatgpt-work-linux" --version) == "chatgpt-work-linux $version" ]]
}

if [[ ! -e $final ]]; then
  install -Dm755 "$binary" "$stage/bin/chatgpt-work-linux"
  install -Dm755 "$repo_root/scripts/inspect-upstream.py" "$stage/lib/chatgpt-work-linux/inspect-upstream.py"
  install -Dm644 "$repo_root/config.example.toml" "$stage/share/doc/chatgpt-work-linux/config.example.toml"
  for document in architecture audit-and-improvement-plan upstream-feature-audit work-upstream-assessment upstream-snapshot codex-desktop-linux-review validation-report; do
    extension=md
    [[ $document == upstream-snapshot ]] && extension=json
    install -Dm644 "$repo_root/docs/$document.$extension" "$stage/share/doc/chatgpt-work-linux/$document.$extension"
  done
  install -Dm644 "$repo_root/assets/ICON-PROVENANCE.md" "$stage/share/doc/chatgpt-work-linux/icon-provenance.md"
  install -Dm644 "$sbom" "$stage/share/doc/chatgpt-work-linux/chatgpt-work-linux.cdx.json"
  install -Dm644 "$repo_root/packaging/linux/io.github.chatgpt_work_linux.desktop" "$stage/share/applications/io.github.chatgpt_work_linux.desktop"
  install -Dm644 "$repo_root/assets/chatgpt-work-linux.png" "$stage/share/icons/hicolor/2048x2048/apps/io.github.chatgpt_work_linux.png"
  install -Dm644 "$repo_root/packaging/linux/io.github.chatgpt_work_linux.metainfo.xml" "$stage/share/metainfo/io.github.chatgpt_work_linux.metainfo.xml"
  install -Dm644 "$repo_root/LICENSE" "$stage/share/licenses/chatgpt-work-linux/LICENSE"
  (cd "$stage" && find bin lib share -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >SHA256SUMS)
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

publish_file "$final/share/applications/io.github.chatgpt_work_linux.desktop" "$desktop_dir/io.github.chatgpt_work_linux.desktop" 0644 "$desktop_dir/.io.github.chatgpt_work_linux.desktop-new-$$"
publish_file "$final/share/icons/hicolor/2048x2048/apps/io.github.chatgpt_work_linux.png" "$icon_dir/io.github.chatgpt_work_linux.png" 0644 "$icon_dir/.io.github.chatgpt_work_linux.png-new-$$"
publish_file "$final/share/metainfo/io.github.chatgpt_work_linux.metainfo.xml" "$metainfo_dir/io.github.chatgpt_work_linux.metainfo.xml" 0644 "$metainfo_dir/.io.github.chatgpt_work_linux.metainfo.xml-new-$$"

ln -s "$base/current/bin/chatgpt-work-linux" "$bin_dir/.chatgpt-work-linux-new-$$"
mv -Tf -- "$bin_dir/.chatgpt-work-linux-new-$$" "$bin_dir/chatgpt-work-linux"
old_target=$(readlink "$base/current" 2>/dev/null || true)
[[ -z $old_target || $old_target == versions/* ]] || { printf 'refusing unexpected current release link: %s\n' "$old_target" >&2; exit 1; }
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
  if find "$candidate" ! -uid "$EUID" -print -quit | grep -q .; then
    printf 'Retaining release containing files owned by another user: %s\n' "$candidate" >&2
    continue
  fi
  chmod -R u+w -- "$candidate"
  rm -rf -- "$candidate"
done

trap - EXIT HUP INT TERM
cleanup
printf 'Installed chatgpt-work-linux %s at %s\n' "$version" "$base/current"
printf 'Launch with: %s\n' "$bin_dir/chatgpt-work-linux"
