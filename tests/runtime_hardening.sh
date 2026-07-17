#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d -t chatgpt-work-runtime-test.XXXXXX)
cleanup() {
  rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

anchor='process.platform===`linux`&&codexLinuxPrewarmHotkeyWindow()'
predicate='function ext(e){return e===`macOS`||e===`windows`}'
availability='featureName:`computer_use`;g=rxt({areRequiredFeaturesEnabled:h,enabled:i,isAnyFeatureLoading:m,isComputerUseGateEnabled:s,isHostCompatiblePlatform:ext(o),isPlatformLoading:a,windowType:`electron`})'
tray_start='(A||process.platform===`linux`)&&Ce()'
tray_wait='if(typeof t.whenReady!=`function`)return process.platform!==`linux`;'
tray_state='return typeof t.isReady==`function`?t.isReady():process.platform!==`linux`'
printf 'prefix%smiddle%snext%safter%sready%sstates%ssuffix' \
  "$anchor" "$predicate" "$availability" "$tray_start" "$tray_wait" "$tray_state" >"$temporary/app.asar"
before_size=$(stat -c %s "$temporary/app.asar")
python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/app.asar"
after_size=$(stat -c %s "$temporary/app.asar")
[[ $before_size == "$after_size" ]] || {
  printf 'runtime_hardening: ASAR patch changed byte length\n' >&2
  exit 1
}
! rg -q 'codexLinuxPrewarmHotkeyWindow' "$temporary/app.asar" || {
  printf 'runtime_hardening: startup prewarm call remains\n' >&2
  exit 1
}
rg -Fq '(A||codexLinuxIsTrayEnabled())&&Ce()' "$temporary/app.asar" || {
  printf 'runtime_hardening: system tray is not gated by the default-on Linux setting\n' >&2
  exit 1
}
rg -Fq 'if(typeof t.whenReady!=`function`)return!0;' "$temporary/app.asar" || {
  printf 'runtime_hardening: standard Electron tray readiness fallback is missing\n' >&2
  exit 1
}
rg -Fq 'return typeof t.isReady==`function`?t.isReady():!0' "$temporary/app.asar" || {
  printf 'runtime_hardening: standard Electron tray state fallback is missing\n' >&2
  exit 1
}
rg -Fq 'function ext(e){return e===`linux`||e===`windows`}' "$temporary/app.asar" || {
  printf 'runtime_hardening: Computer Use Linux availability predicate is missing\n' >&2
  exit 1
}
rg -Fq 'areRequiredFeaturesEnabled:1,enabled:i,isAnyFeatureLoading:0,isComputerUseGateEnabled:1,isHostCompatiblePlatform:ext(o)' "$temporary/app.asar" || {
  printf 'runtime_hardening: Computer Use Linux feature gates remain conditional\n' >&2
  exit 1
}
if python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/app.asar" >/dev/null 2>&1; then
  printf 'runtime_hardening: patcher accepted an already-patched input\n' >&2
  exit 1
fi

printf '%s%s%s%s%s%s%s' "$anchor" "$anchor" "$predicate" "$availability" "$tray_start" "$tray_wait" "$tray_state" >"$temporary/ambiguous.asar"
if python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/ambiguous.asar" >/dev/null 2>&1; then
  printf 'runtime_hardening: patcher accepted an ambiguous input\n' >&2
  exit 1
fi

printf '%s%s%s%s%s' "$anchor" "$availability" "$tray_start" "$tray_wait" "$tray_state" >"$temporary/missing-computer-use-predicate.asar"
if python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/missing-computer-use-predicate.asar" >/dev/null 2>&1; then
  printf 'runtime_hardening: patcher accepted a missing Computer Use predicate\n' >&2
  exit 1
fi

printf '%s%s%s%s%s' "$anchor" "$predicate" "$tray_start" "$tray_wait" "$tray_state" >"$temporary/missing-computer-use-call.asar"
if python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/missing-computer-use-call.asar" >/dev/null 2>&1; then
  printf 'runtime_hardening: patcher accepted a missing Computer Use availability call\n' >&2
  exit 1
fi

printf '%s%s%s%s%s' "$anchor" "$predicate" "$availability" "$tray_wait" "$tray_state" >"$temporary/missing-tray-start.asar"
if python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/missing-tray-start.asar" >/dev/null 2>&1; then
  printf 'runtime_hardening: patcher accepted a missing tray startup branch\n' >&2
  exit 1
fi

printf '%s%s%s%s%s' "$anchor" "$predicate" "$availability" "$tray_start" "$tray_state" >"$temporary/missing-tray-readiness.asar"
if python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/missing-tray-readiness.asar" >/dev/null 2>&1; then
  printf 'runtime_hardening: patcher accepted a missing portable tray readiness fallback\n' >&2
  exit 1
fi

valid_report="$temporary/valid-report.json"
printf '%s\n' '{"enabledFeatures":[],"patches":[' \
  '{"name":"linux-explicit-tray-quit","status":"applied"},' \
  '{"name":"linux-launch-actions","status":"applied"},' \
  '{"name":"linux-settings-persistence","status":"already-applied"},' \
  '{"name":"linux-single-instance","status":"already-applied"},' \
  '{"name":"linux-tray","status":"applied"},' \
  '{"name":"linux-computer-use-ui-feature","status":"applied"},' \
  '{"name":"linux-computer-use-plugin-gate","status":"already-applied"},' \
  '{"name":"linux-computer-use-native-desktop-apps","status":"applied"},' \
  '{"name":"linux-computer-use-ui-availability","status":"applied"},' \
  '{"name":"linux-computer-use-install-flow","status":"applied"}' \
  ']}' | tr -d '\n' >"$valid_report"
python3 "$repo_root/scripts/validate-work-patch-report.py" "$valid_report" >/dev/null

invalid_report="$temporary/invalid-report.json"
sed 's/"linux-computer-use-ui-availability","status":"applied"/"linux-computer-use-ui-availability","status":"skipped-disabled"/' \
  "$valid_report" >"$invalid_report"
if python3 "$repo_root/scripts/validate-work-patch-report.py" "$invalid_report" >/dev/null 2>&1; then
  printf 'runtime_hardening: validator accepted a disabled Computer Use UI patch\n' >&2
  exit 1
fi

invalid_warm_report="$temporary/invalid-warm-report.json"
sed 's/"linux-launch-actions","status":"applied"/"linux-launch-actions","status":"skipped-optional"/' \
  "$valid_report" >"$invalid_warm_report"
if python3 "$repo_root/scripts/validate-work-patch-report.py" "$invalid_warm_report" >/dev/null 2>&1; then
  printf 'runtime_hardening: validator accepted disabled warm-start launch actions\n' >&2
  exit 1
fi

unexpected_feature_report="$temporary/unexpected-feature-report.json"
sed 's/"enabledFeatures":\[\]/"enabledFeatures":["open-target-discovery"]/' \
  "$valid_report" >"$unexpected_feature_report"
if python3 "$repo_root/scripts/validate-work-patch-report.py" "$unexpected_feature_report" >/dev/null 2>&1; then
  printf 'runtime_hardening: validator accepted an unreviewed Linux feature\n' >&2
  exit 1
fi

launcher_fixture="$temporary/start.sh"
cat >"$launcher_fixture" <<'SH'
#!/usr/bin/env bash
CODEX_LINUX_WEBVIEW_PORT=${CODEX_WEBVIEW_PORT:-5176}
CODEX_LINUX_APP_ID=io.github.chatgpt_work_linux
if [ -z "${CODEX_HOME:-}" ]; then
    if [ -n "${HOME:-}" ]; then
        CODEX_HOME="$HOME/.codex"
    else
        CODEX_HOME=""
    fi
fi
export CODEX_HOME CODEX_LINUX_APP_ID CODEX_LINUX_APP_DISPLAY_NAME
APP_NOTIFICATION_ICON_NAME="$CODEX_LINUX_APP_ID"
    ELECTRON_LAUNCH_ARGS=(
        --no-sandbox
        --class="$CODEX_LINUX_APP_ID"
        --app-id="$CODEX_LINUX_APP_ID"
        --disable-gpu-sandbox
    )
    run_packaged_runtime_prelaunch
    log_phase "packaged_prelaunch"
    start_webview_server
if ! truthy_env_value "${CODEX_LINUX_ALLOW_RENDERER_URL_OVERRIDE:-}"; then
    if [ -n "${ELECTRON_RENDERER_URL:-}" ] && [ "$ELECTRON_RENDERER_URL" != "$WEBVIEW_ORIGIN/" ]; then
        echo "Ignoring inherited ELECTRON_RENDERER_URL; set CODEX_LINUX_ALLOW_RENDERER_URL_OVERRIDE=1 to allow overrides"
    fi
    export ELECTRON_RENDERER_URL="$WEBVIEW_ORIGIN/"
else
    export ELECTRON_RENDERER_URL="${ELECTRON_RENDERER_URL:-$WEBVIEW_ORIGIN/}"
fi
    await_webview_server_ready
fi
resolve_browser_use_runtime_env
recover_unhealthy_running_app() {
    running_app_is_active || return 0
    webview_origin_is_reachable && return 0
    echo "Detected live Electron with an unavailable packaged webview origin"
    if ! terminate_stale_electron_with_pidfd "$RUNNING_APP_PID"; then
        exit 1
    fi
}

send_warm_start_launch_action() {
    return 0
}
    exec >>"$LOG_FILE" 2>&1
"$SCRIPT_DIR/electron"
SH
chmod +x "$launcher_fixture"
python3 "$repo_root/scripts/configure-work-runtime.py" "$launcher_fixture" \
  --upstream-version 26.715.21425
rg -Fq 'CODEX_ELECTRON_DISABLE_GPU_COMPOSITING=0' "$launcher_fixture" || {
  printf 'runtime_hardening: native Wayland GPU compositing default is missing\n' >&2
  exit 1
}
rg -Fq 'CODEX_FORCE_RENDERER_ACCESSIBILITY=0' "$launcher_fixture" || {
  printf 'runtime_hardening: bounded renderer accessibility default is missing\n' >&2
  exit 1
}
rg -Fq -- '--force-prefers-reduced-motion' "$launcher_fixture" || {
  printf 'runtime_hardening: low-CPU reduced-motion default is missing\n' >&2
  exit 1
}
rg -Fq 'CODEX_HOME="$HOME/.codex"' "$launcher_fixture" || {
  printf 'runtime_hardening: canonical Codex history home is missing\n' >&2
  exit 1
}
rg -Fq 'if [ -n "${CHATGPT_WORK_CODEX_HOME:-}" ]; then' "$launcher_fixture" || {
  printf 'runtime_hardening: disposable Codex home override is missing\n' >&2
  exit 1
}
! rg -Fq 'CODEX_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/$CODEX_LINUX_APP_ID/codex-home"' "$launcher_fixture" || {
  printf 'runtime_hardening: launcher still splits local Codex history\n' >&2
  exit 1
}
! rg -q -- '--no-sandbox|--disable-gpu-sandbox|start_webview_server$' "$launcher_fixture" || {
  printf 'runtime_hardening: configured launcher retained an unsafe runtime path\n' >&2
  exit 1
}
rg -Fq 'preserving it for Electron second-instance handoff' "$launcher_fixture" || {
  printf 'runtime_hardening: packaged app recovery does not preserve the running process\n' >&2
  exit 1
}
rg -Fq 'WARM_START=0' "$launcher_fixture" || {
  printf 'runtime_hardening: missing launch socket does not select second-instance handoff\n' >&2
  exit 1
}
if rg -Fq 'webview_origin_is_reachable && return 0' "$launcher_fixture"; then
  printf 'runtime_hardening: packaged app recovery retained the obsolete localhost health probe\n' >&2
  exit 1
fi

server_fixture="$temporary/server.rs"
python3 - "$repo_root/scripts/patch-computer-use-wayland.py" "$server_fixture" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("wayland_patch", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
with open(sys.argv[2], "w", encoding="utf-8") as fixture:
    fixture.write("prefix\n")
    for _name, originals, _patched in module.TRANSFORMS:
        fixture.write(originals[0])
        fixture.write("\n")
    fixture.write("suffix\n")
PY
python3 "$repo_root/scripts/patch-computer-use-wayland.py" "$server_fixture" >/dev/null
rg -Fq 'Action sent through the Wayland remote desktop portal.' "$server_fixture" || {
  printf 'runtime_hardening: Wayland press_key portal patch is missing\n' >&2
  exit 1
}
rg -Fq 'let focus = match self.focus_target_for_input(&params.window_target()).await' "$server_fixture" || {
  printf 'runtime_hardening: final keyboard focus revalidation is missing\n' >&2
  exit 1
}
rg -Fq 'ydotool is disabled on Wayland; a consented XDG Remote Desktop portal session is required' "$server_fixture" || {
  printf 'runtime_hardening: Wayland ydotool fail-closed guard is missing\n' >&2
  exit 1
}
rg -Fq 'if self.should_prefer_kde_clipboard_text_backend() && !params.window_target().has_target()' "$server_fixture" || {
  printf 'runtime_hardening: targeted KDE clipboard race guard is missing\n' >&2
  exit 1
}
rg -Fq 'fn should_prefer_portal_pointer_backend(&self) -> bool {' "$server_fixture" || {
  printf 'runtime_hardening: Wayland portal pointer preference is missing\n' >&2
  exit 1
}
if rg -q 'ydotool_backend_available|should_prefer_portal_backend_by_default' "$server_fixture"; then
  printf 'runtime_hardening: obsolete ydotool availability probes remain\n' >&2
  exit 1
fi
python3 "$repo_root/scripts/patch-computer-use-wayland.py" "$server_fixture" >/dev/null
printf 'drifted\n' >"$server_fixture"
if python3 "$repo_root/scripts/patch-computer-use-wayland.py" "$server_fixture" >/dev/null 2>&1; then
  printf 'runtime_hardening: Wayland press_key patcher accepted drifted source\n' >&2
  exit 1
fi

printf 'runtime_hardening: all tests passed\n'
