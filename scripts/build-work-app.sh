#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
dmg=${1:-"$repo_root/ChatGPT-work.dmg"}
output=${CHATGPT_WORK_BUILD_DIR:-"$repo_root/.work/chatgpt-work-app"}

fail() {
  printf 'build-work-app: %s\n' "$*" >&2
  exit 1
}

[[ -f $dmg ]] || fail "missing official ChatGPT input: $dmg"
readarray -t expected < <(python3 - "$repo_root/docs/upstream-snapshot.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    snapshot = json.load(handle)
print(snapshot["application"]["short_version"])
print(snapshot["artifact"]["sha256"])
print(snapshot["artifact"]["size"])
print(snapshot["source"]["url"])
PY
)
version=${expected[0]}
expected_sha256=${expected[1]}
expected_size=${expected[2]}
source_url=${expected[3]}
[[ $source_url == https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg ]] ||
  fail "snapshot is not tied to the official ChatGPT.dmg URL: $source_url"
actual_size=$(stat -c %s -- "$dmg")
(( actual_size > 500 * 1024 * 1024 )) || fail "artifact is too small for unified ChatGPT: $actual_size bytes"
[[ $actual_size == "$expected_size" ]] || fail "artifact size differs from snapshot: $actual_size"
actual_sha256=$(sha256sum "$dmg" | awk '{print $1}')
[[ $actual_sha256 == "$expected_sha256" ]] || fail "artifact SHA-256 differs from snapshot: $actual_sha256"

adapter=$("$repo_root/scripts/prepare-compat-adapter.sh")
adapter_commit=$(<"$adapter/.chatgpt-work-adapter-commit")
report_dir=${CHATGPT_WORK_REPORT_DIR:-"$repo_root/.work/reports/$version"}
cargo_target_dir=${CHATGPT_WORK_CARGO_TARGET_DIR:-"$adapter/target"}
parent=$(dirname -- "$output")
stage="$parent/.stage-$(basename -- "$output")-$$"
cleanup() {
  rm -rf -- "$stage"
}
trap cleanup EXIT HUP INT TERM
mkdir -p -- "$parent" "$report_dir"
rm -rf -- "$stage"

printf 'Building ChatGPT Work %s with adapter %s...\n' "$version" "${adapter_commit:0:12}" >&2
CODEX_APP_ID=io.github.chatgpt_work_linux \
CODEX_APP_DISPLAY_NAME='ChatGPT Work Linux (Unofficial)' \
CODEX_INSTALL_DIR="$stage" \
CODEX_LINUX_ICON_SOURCE="$repo_root/assets/chatgpt-work-linux.png" \
CODEX_PATCH_REPORT_JSON="$report_dir/patch-report.json" \
CODEX_REBUILD_REPORT_JSON="$report_dir/rebuild-report.json" \
REBUILD_REPORT_DIR="$report_dir" \
CARGO_TARGET_DIR="$cargo_target_dir" \
  "$adapter/install.sh" "$dmg"

node "$adapter/scripts/ci/validate-patch-report.js" \
  "$report_dir/patch-report.json" --profile upstream-build
python3 "$repo_root/scripts/patch-work-asar.py" "$stage/resources/app.asar"
python3 "$repo_root/scripts/configure-work-runtime.py" \
  "$stage/start.sh" --upstream-version "$version"
rm -f -- "$stage/.codex-linux/webview-server.py"
mv -- "$stage/electron" "$stage/chatgpt-work-linux-bin"

[[ -x $stage/chatgpt-work-linux-bin ]] || fail 'Linux Electron executable is missing'
[[ -x $stage/start.sh ]] || fail 'launcher is missing'
[[ -s $stage/resources/app.asar ]] || fail 'patched app.asar is missing'
[[ -f $stage/content/webview/index.html ]] || fail 'packaged renderer is missing'
[[ ! -e $stage/.codex-linux/webview-server.py ]] || fail 'local HTTP server was packaged'
if rg -n -- '--no-sandbox|--disable-gpu-sandbox|start_webview_server$|export ELECTRON_RENDERER_URL=' "$stage/start.sh" >/dev/null; then
  fail 'launcher contains a sandbox bypass or local-server renderer path'
fi
rg -q 'unset ELECTRON_RENDERER_URL' "$stage/start.sh" || fail 'packaged app:// renderer is not enforced'
rg -q 'CODEX_OZONE_PLATFORM=wayland' "$stage/start.sh" || fail 'Wayland is not the default runtime'
rg -q 'CODEX_LINUX_DESKTOP_ID=io.github.chatgpt_work_linux' "$stage/start.sh" || fail 'desktop identity is missing'
rg -q 'CODEX_LINUX_EXECUTABLE_NAME=chatgpt-work-linux-bin' "$stage/start.sh" || fail 'packaged executable identity is missing'
ldd "$stage/chatgpt-work-linux-bin" | rg -q 'not found' && fail 'Electron has unresolved shared libraries'
bash -n "$stage/start.sh"
"$stage/resources/node-runtime/bin/node" --version | rg -q '^v22\.' || fail 'managed Node runtime failed validation'

rm -rf -- "$stage/resources/node-runtime/include" "$stage/resources/node-runtime/share"
rm -f -- "$stage/resources/node-runtime/bin/corepack" "$stage/resources/node-runtime/bin/npm" \
  "$stage/resources/node-runtime/bin/npx" "$stage/resources/node-runtime/CHANGELOG.md" \
  "$stage/resources/node-runtime/README.md"
printf '%s\n' "$adapter_commit" >"$stage/.codex-linux/adapter-commit"
(
  cd "$stage"
  find . -type f ! -path './.codex-linux/SHA256SUMS' -print0 |
    LC_ALL=C sort -z | xargs -0 sha256sum >.codex-linux/SHA256SUMS
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
trap - EXIT HUP INT TERM
printf 'Built %s from ChatGPT %s (%s)\n' "$output" "$version" "$(du -sh "$output" | awk '{print $1}')"
