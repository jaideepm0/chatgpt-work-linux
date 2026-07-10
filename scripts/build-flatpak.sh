#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
manifest="$repo_root/packaging/flatpak/io.github.chatgpt_work_linux.yml"
build_dir="$repo_root/.work/flatpak-build"
repo_dir="$repo_root/.work/flatpak-repo"
version=$(awk -F '"' '/^version = "/ { print $2; exit }' "$repo_root/Cargo.toml")
bundle="$repo_root/dist/chatgpt-work-linux-$version-$(uname -m).flatpak"

command -v flatpak-builder >/dev/null 2>&1 || {
  printf 'flatpak-builder is required\n' >&2
  exit 1
}

rm -rf -- "$build_dir"
mkdir -p -- "$repo_root/dist"
flatpak-builder \
  --force-clean \
  --disable-rofiles-fuse \
  --repo="$repo_dir" \
  "$build_dir" \
  "$manifest"

flatpak build-bundle "$repo_dir" "$bundle" io.github.chatgpt_work_linux master
printf 'Flatpak repository written to %s\n' "$repo_dir"
printf 'Flatpak bundle written to %s\n' "$bundle"
printf 'Install with: flatpak install --user --reinstall --bundle %s\n' "$bundle"
