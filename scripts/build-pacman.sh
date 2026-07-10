#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
version=$(awk -F '"' '/^version = "/ { print $2; exit }' "$repo_root/Cargo.toml")
if [[ ! $version =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]]; then
  printf 'could not determine a safe package version\n' >&2
  exit 1
fi

work="$repo_root/.work/pacman-$version-$$"
source_root="$work/source/chatgpt-work-linux-$version"
archive="$work/chatgpt-work-linux-$version.tar.gz"
cleanup() {
  rm -rf -- "$work"
}
trap cleanup EXIT

mkdir -p "$source_root" "$repo_root/dist"
cp -a -- \
  "$repo_root/Cargo.lock" \
  "$repo_root/Cargo.toml" \
  "$repo_root/LICENSE" \
  "$repo_root/config.example.toml" \
  "$repo_root/assets" \
  "$repo_root/docs" \
  "$repo_root/packaging/linux" \
  "$repo_root/scripts" \
  "$repo_root/src" \
  "$source_root/"

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

sed \
  -e "s/@PKGVER@/$version/g" \
  -e "s/@SOURCE_SHA256@/$source_sha256/g" \
  "$repo_root/packaging/arch/PKGBUILD" >"$work/PKGBUILD"
cp -- "$archive" "$work/"

(
  cd "$work"
  env \
    PKGDEST="$repo_root/dist" \
    CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" \
    makepkg --force --cleanbuild --clean --nodeps "$@"
)

printf 'Packages written to %s\n' "$repo_root/dist"
