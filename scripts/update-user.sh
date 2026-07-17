#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
(( EUID != 0 )) || { printf 'update-user must run as the desktop user\n' >&2; exit 2; }

printf 'Refreshing the exact official upstream snapshot...\n'
make -C "$repo_root" refresh-upstream
printf 'Running repository and drift checks...\n'
make -C "$repo_root" check
printf 'Building and validating the reviewed compatibility transaction...\n'
make -C "$repo_root" build
make -C "$repo_root" smoke-wayland
printf 'Publishing the immutable user release...\n'
make -C "$repo_root" install-user
printf 'Update completed. Reopen a previously running app to use the new release.\n'
