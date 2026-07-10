#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
version=$(awk -F '"' '/^version = "/ { print $2; exit }' "$repo_root/Cargo.toml")
if [[ ! $version =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]]; then
  printf 'could not determine a safe package version\n' >&2
  exit 1
fi

mkdir -p "$repo_root/.work" "$repo_root/.cache"
exec 9>"$repo_root/.work/pacman.lock"
flock 9
work="$repo_root/.work/pacman-$version"
rm -rf -- "$work"
source_root="$work/source/chatgpt-work-linux-$version"
archive="$work/chatgpt-work-linux-$version.tar.gz"
cleanup() {
  rm -rf -- "$work"
}
trap cleanup EXIT

mkdir -p "$source_root/packaging" "$repo_root/dist"
cp -a -- \
  "$repo_root/Cargo.lock" \
  "$repo_root/Cargo.toml" \
  "$repo_root/LICENSE" \
  "$repo_root/config.example.toml" \
  "$repo_root/assets" \
  "$repo_root/docs" \
  "$repo_root/scripts" \
  "$repo_root/src" \
  "$source_root/"
cp -a -- "$repo_root/packaging/linux" "$source_root/packaging/"

tar \
  --sort=name \
  --mtime='@0' \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --pax-option=delete=atime,delete=ctime \
  -C "$work/source" \
  -czf "$archive" \
  "chatgpt-work-linux-$version"
source_sha256=$(sha256sum "$archive" | awk '{print $1}')
target_cache="$repo_root/.cache/pacman-target-$version-$source_sha256"

sed \
  -e "s/@PKGVER@/$version/g" \
  -e "s/@SOURCE_SHA256@/$source_sha256/g" \
  "$repo_root/packaging/arch/PKGBUILD" >"$work/PKGBUILD"

(
  cd "$work"
  env \
    PKGDEST="$repo_root/dist" \
    CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" \
    CARGO_TARGET_DIR="$target_cache" \
    makepkg --force --cleanbuild --clean --nodeps "$@"
)

for candidate in "$repo_root/.cache/pacman-target-$version-"*; do
  [[ -d $candidate && $candidate != "$target_cache" ]] || continue
  rm -rf -- "$candidate"
done

printf 'Packages written to %s\n' "$repo_root/dist"
