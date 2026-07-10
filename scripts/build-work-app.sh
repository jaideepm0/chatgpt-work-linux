#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
compat_root="$repo_root/compat/codex-desktop-linux"
dmg=${1:-"$repo_root/ChatGPT-work.dmg"}
output=${CHATGPT_WORK_BUILD_DIR:-"$repo_root/.work/chatgpt-work-app"}
report_dir=${CHATGPT_WORK_REPORT_DIR:-"$repo_root/.work/reports/26.707.31428"}
expected_sha256=6f67af7e2f934093ab8afebcec11374d40c8db8f9100fb6620f24155401d8319

fail() {
  printf 'build-work-app: %s\n' "$*" >&2
  exit 1
}

[[ -f $dmg ]] || fail "missing upstream input: $dmg"
actual_sha256=$(sha256sum "$dmg" | awk '{print $1}')
[[ $actual_sha256 == "$expected_sha256" ]] ||
  fail "unexpected DMG SHA-256: $actual_sha256"

parent=$(dirname -- "$output")
mkdir -p "$parent" "$report_dir"
stage="$parent/.stage-$(basename -- "$output")-$$"
cleanup() {
  rm -rf -- "$stage"
}
trap cleanup EXIT HUP INT TERM
rm -rf -- "$stage"

printf 'Building ChatGPT Work 26.707.31428 from verified local input...\n' >&2
CODEX_APP_ID=chatgpt-work-linux \
CODEX_APP_DISPLAY_NAME='ChatGPT Work Linux (Unofficial)' \
CODEX_INSTALL_DIR="$stage" \
CODEX_LINUX_ICON_SOURCE="$repo_root/assets/chatgpt-work-linux.png" \
CODEX_PATCH_REPORT_JSON="$report_dir/patch-report.json" \
CODEX_REBUILD_REPORT_JSON="$report_dir/rebuild-report.json" \
REBUILD_REPORT_DIR="$report_dir" \
  "$compat_root/install.sh" "$dmg"

node "$compat_root/scripts/ci/validate-patch-report.js" \
  "$report_dir/patch-report.json" --profile upstream-build

[[ -x $stage/chatgpt-work-linux-bin ]] || fail 'packaged Electron executable is missing'
[[ -x $stage/start.sh ]] || fail 'launcher is missing'
[[ -s $stage/resources/app.asar ]] || fail 'patched app.asar is missing'
[[ -f $stage/content/webview/index.html ]] || fail 'staged app:// renderer is missing'
[[ ! -e $stage/.codex-linux/webview-server.py ]] || fail 'loopback server was packaged'
if npx --yes asar list "$stage/resources/app.asar" | rg -q '^/webview/'; then
  fail 'renderer is duplicated inside app.asar'
fi
cmp -s "$repo_root/assets/chatgpt-work-linux.png" \
  "$stage/.codex-linux/app-icon.png" || fail 'application icon mismatch'

if rg -n -- '--no-sandbox|--disable-gpu-sandbox|python3 .*webview-server\.py' "$stage/start.sh" >/dev/null; then
  fail 'launcher contains a forbidden sandbox or loopback-renderer path'
fi
rg -q 'unset ELECTRON_RENDERER_URL' "$stage/start.sh" ||
  fail 'launcher does not enforce the packaged app:// renderer'
rg -q 'CODEX_LINUX_EXECUTABLE_NAME=chatgpt-work-linux-bin' "$stage/start.sh" ||
  fail 'Electron will not identify this as a packaged application'

# Build headers and package managers are unnecessary after native modules are
# compiled. Browser-use only needs the pinned Node executable and node_repl.
rm -rf -- \
  "$stage/resources/node-runtime/include" \
  "$stage/resources/node-runtime/lib" \
  "$stage/resources/node-runtime/share"
rm -f -- \
  "$stage/resources/node-runtime/bin/corepack" \
  "$stage/resources/node-runtime/bin/npm" \
  "$stage/resources/node-runtime/bin/npx" \
  "$stage/resources/node-runtime/CHANGELOG.md" \
  "$stage/resources/node-runtime/README.md"

ldd "$stage/chatgpt-work-linux-bin" | rg -q 'not found' &&
  fail 'Electron has unresolved shared-library dependencies'
"$stage/resources/node-runtime/bin/node" --version | rg -q '^v22\.' ||
  fail 'managed Node runtime failed its version check'
bash -n "$stage/start.sh"

(
  cd "$stage"
  find . -type f ! -path './.codex-linux/SHA256SUMS' -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum \
    >.codex-linux/SHA256SUMS
)

previous="$output.previous"
rm -rf -- "$previous"
if [[ -e $output ]]; then
  mv -- "$output" "$previous"
fi
if ! mv -- "$stage" "$output"; then
  [[ ! -e $output && -e $previous ]] && mv -- "$previous" "$output"
  fail 'could not publish the completed build'
fi
trap - EXIT

size=$(du -sh "$output" | awk '{print $1}')
printf 'Built %s (%s)\n' "$output" "$size"
printf 'Patch report: %s\n' "$report_dir/patch-report.json"
