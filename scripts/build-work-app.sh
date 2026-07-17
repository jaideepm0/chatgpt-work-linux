#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
dmg=${1:-"${CHATGPT_WORK_DMG_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux/upstream/ChatGPT-work.dmg}"}
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
linux_features_config="$repo_root/config/linux-features.json"
[[ $source_url == https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg ]] ||
  fail "snapshot is not tied to the official ChatGPT.dmg URL: $source_url"
[[ -s $linux_features_config ]] || fail "Linux feature configuration is missing"
actual_size=$(stat -c %s -- "$dmg")
(( actual_size > 500 * 1024 * 1024 )) || fail "artifact is too small for unified ChatGPT: $actual_size bytes"
[[ $actual_size == "$expected_size" ]] || fail "artifact size differs from snapshot: $actual_size"
actual_sha256=$(sha256sum "$dmg" | awk '{print $1}')
[[ $actual_sha256 == "$expected_sha256" ]] || fail "artifact SHA-256 differs from snapshot: $actual_sha256"

adapter_archive=$("$repo_root/scripts/prepare-compat-adapter.sh")
adapter_commit=$(<"$adapter_archive/.chatgpt-work-adapter-commit")
report_dir=${CHATGPT_WORK_REPORT_DIR:-"$repo_root/.work/reports/$version"}
cargo_target_dir=${CHATGPT_WORK_CARGO_TARGET_DIR:-"${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux/cargo/$adapter_commit"}
parent=$(dirname -- "$output")
stage="$parent/.stage-$(basename -- "$output")-$$"
adapter="$parent/.adapter-$adapter_commit-$$"
cleanup() {
  rm -rf -- "$stage" "$adapter"
}
trap cleanup EXIT HUP INT TERM
mkdir -p -- "$parent" "$report_dir"
rm -rf -- "$stage" "$adapter"
cp -a --reflink=auto -- "$adapter_archive" "$adapter"
rm -f -- "$adapter/.chatgpt-work-adapter-integrity"
mkdir -p -- "$cargo_target_dir"
ln -s -- "$cargo_target_dir" "$adapter/target"
python3 "$repo_root/scripts/patch-compat-adapter.py" "$adapter"
python3 "$repo_root/scripts/patch-computer-use-wayland.py" \
  "$adapter/computer-use-linux/src/server.rs"

printf 'Building ChatGPT Work %s with adapter %s...\n' "$version" "${adapter_commit:0:12}" >&2
CODEX_LINUX_ENABLE_COMPUTER_USE_UI=1 \
CODEX_LINUX_FEATURES_CONFIG="$linux_features_config" \
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
python3 "$repo_root/scripts/validate-work-patch-report.py" \
  "$report_dir/patch-report.json"
python3 "$repo_root/scripts/patch-work-asar.py" "$stage/resources/app.asar"
python3 "$repo_root/scripts/configure-work-runtime.py" \
  "$stage/start.sh" --upstream-version "$version"

# The unified ChatGPT tray factory resolves the reviewed production brand to
# resources/icon-chatgpt.png. The adapter-provided desktop icon is the same
# unmodified public OpenAI icon, but the generic installer stores it outside
# resources. Preserve one small local copy at the exact packaged-runtime path.
python3 - "$stage/resources/app.asar" <<'PY'
from pathlib import Path
import sys

payload = Path(sys.argv[1]).read_bytes()
anchors = {
    b"case i.a.Dev:case i.a.Prod:return`icon-chatgpt`": "ChatGPT production tray brand",
    b"if(process.platform===`linux`){let r=`${fv(e,t)}.png`": "Linux tray resource lookup",
    b"(A||codexLinuxIsTrayEnabled())&&Ce() ": "default-on Linux tray startup",
}
for anchor, label in anchors.items():
    count = payload.count(anchor)
    if count != 1:
        raise SystemExit(f"build-work-app: expected one {label} anchor, found {count}")
PY
install -m 0644 -- "$repo_root/assets/chatgpt-work-linux.png" \
  "$stage/resources/icon-chatgpt.png"
rm -f -- "$stage/.codex-linux/webview-server.py"
# The app:// scheme reads the renderer from app.asar. Keep only the one native
# BrowserWindow icon that the reviewed Linux patch addresses by filesystem
# path; the rest is a retired localhost-server duplicate (~189 MiB).
readarray -t external_icon_paths < <(
  rg -a -o 'content/webview/assets/app-[A-Za-z0-9_-]+\.png' \
    "$stage/resources/app.asar" | LC_ALL=C sort -u
)
[[ ${#external_icon_paths[@]} -eq 1 ]] || \
  fail "expected one external Linux window icon path, found ${#external_icon_paths[@]}"
external_icon=${external_icon_paths[0]}
[[ -s $stage/$external_icon ]] || fail "external Linux window icon is missing: $external_icon"
icon_copy="$stage/.linux-window-icon"
cp -- "$stage/$external_icon" "$icon_copy"
rm -rf -- "$stage/content"
mkdir -p -- "$stage/$(dirname -- "$external_icon")"
mv -- "$icon_copy" "$stage/$external_icon"
mv -- "$stage/electron" "$stage/chatgpt-work-linux-bin"

[[ -x $stage/chatgpt-work-linux-bin ]] || fail 'Linux Electron executable is missing'
[[ -x $stage/start.sh ]] || fail 'launcher is missing'
[[ -s $stage/resources/app.asar ]] || fail 'patched app.asar is missing'
[[ -s $stage/resources/icon-chatgpt.png ]] || fail 'system tray icon is missing'
python3 - "$stage/resources/icon-chatgpt.png" <<'PY'
from pathlib import Path
import sys

if Path(sys.argv[1]).read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit("build-work-app: system tray icon is not a PNG")
PY
[[ -s $stage/$external_icon ]] || fail 'minimal external Linux window icon was not preserved'
[[ $(find "$stage/content" -type f | wc -l) -eq 1 ]] || \
  fail 'obsolete localhost renderer files were packaged'
computer_use_plugin="$stage/resources/plugins/openai-bundled/plugins/computer-use"
computer_use_backend="$computer_use_plugin/bin/codex-computer-use-linux"
[[ -x $computer_use_backend ]] || fail 'Linux Computer Use backend is missing or not executable'
[[ -s $computer_use_plugin/.mcp.json ]] || fail 'Linux Computer Use MCP manifest is missing'
[[ -s $computer_use_plugin/.codex-plugin/plugin.json ]] || fail 'Linux Computer Use plugin manifest is missing'
"$computer_use_backend" --help | rg -q 'codex-computer-use-linux mcp' || \
  fail 'Linux Computer Use backend self-check failed'
rg -a -Fq \
  'ydotool is disabled on Wayland; a consented XDG Remote Desktop portal session is required' \
  "$computer_use_backend" || \
  fail 'Linux Computer Use portal-only Wayland guard is missing'
[[ ! -e $stage/.codex-linux/webview-server.py ]] || fail 'local HTTP server was packaged'
if rg -n -- '--no-sandbox|--disable-gpu-sandbox|start_webview_server$|export ELECTRON_RENDERER_URL=' "$stage/start.sh" >/dev/null; then
  fail 'launcher contains a sandbox bypass or local-server renderer path'
fi
rg -q 'unset ELECTRON_RENDERER_URL' "$stage/start.sh" || fail 'packaged app:// renderer is not enforced'
rg -q 'CODEX_OZONE_PLATFORM=wayland' "$stage/start.sh" || fail 'Wayland is not the default runtime'
rg -q 'CODEX_LINUX_DESKTOP_ID=io.github.chatgpt_work_linux' "$stage/start.sh" || fail 'desktop identity is missing'
rg -q 'CODEX_LINUX_EXECUTABLE_NAME=chatgpt-work-linux-bin' "$stage/start.sh" || fail 'packaged executable identity is missing'
if rg -a -Fq 'function codexLinuxDiscoveredIdeTargets(' "$stage/resources/app.asar" ||
   rg -a -Fq 'codexLinuxWorkspaceRootOpenTarget:' "$stage/resources/app.asar"; then
  fail 'disabled editor-discovery integration was unexpectedly packaged'
fi
for runtime_anchor in \
  'codexLinuxGetSetting=e=>process.platform!==`linux`||P.globalState.get(e)!==!1' \
  'codexLinuxIsTrayEnabled=()=>codexLinuxGetSetting(`codex-linux-system-tray-enabled`)' \
  'codexLinuxIsWarmStartEnabled=()=>codexLinuxGetSetting(`codex-linux-warm-start-enabled`)' \
  'if(typeof t.whenReady!=`function`)return!0;' \
  'return typeof t.isReady==`function`?t.isReady():!0' \
  'codexLinuxStartLaunchActionSocket=()=>' \
  'codexLinuxDefaultLaunchActionSocket=()=>' \
  'codexLinuxRegisterTray(new' \
  'canHideLastWindowToTray?.()===!0'; do
  rg -a -Fq "$runtime_anchor" "$stage/resources/app.asar" || \
    fail "required tray/warm-start runtime anchor is missing: $runtime_anchor"
done
rg -Fq 'linux_setting_enabled "codex-linux-warm-start-enabled" 1' "$stage/start.sh" || \
  fail 'warm-start launcher setting is not default-on'
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
