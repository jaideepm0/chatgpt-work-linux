#!/usr/bin/env bash
set -euo pipefail

launcher=${1:-"$HOME/.local/bin/chatgpt-work-linux"}
[[ $launcher == /* ]] || launcher=$(realpath -- "$launcher")
[[ -x $launcher ]] || { printf 'smoke-wayland: launcher is not executable: %s\n' "$launcher" >&2; exit 2; }
[[ ${XDG_SESSION_TYPE:-} == wayland && -n ${WAYLAND_DISPLAY:-} ]] || {
  printf 'smoke-wayland: an active Wayland session is required\n' >&2
  exit 2
}

temporary=$(mktemp -d -t chatgpt-work-wayland.XXXXXX)
session_runtime=${XDG_RUNTIME_DIR:?smoke-wayland: XDG_RUNTIME_DIR is required}
launcher_pid=
electron_pid=
cleanup() {
  [[ -z ${electron_pid:-} ]] || kill "$electron_pid" 2>/dev/null || true
  [[ -z ${launcher_pid:-} ]] || kill "$launcher_pid" 2>/dev/null || true
  rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM
mkdir -m 0700 -- "$temporary/runtime"
ln -s -- "$session_runtime/$WAYLAND_DISPLAY" "$temporary/runtime/$WAYLAND_DISPLAY"
mkdir -p -- "$temporary/config" "$temporary/data" "$temporary/cache" "$temporary/state"

doctor=$(XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY="$WAYLAND_DISPLAY" "$launcher" doctor --json)
python3 - "$doctor" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
assert report["runtime"] == "electron"
assert report["waylandSession"] is True
assert report["sandboxDisabled"] is False
assert report["rendererOrigin"] == "app://"
PY

runtime_root=$(dirname -- "$(readlink -f -- "$launcher")")
computer_use_backend="$runtime_root/resources/plugins/openai-bundled/plugins/computer-use/bin/codex-computer-use-linux"
[[ -x $computer_use_backend ]] || {
  printf 'smoke-wayland: Computer Use backend is missing or not executable: %s\n' "$computer_use_backend" >&2
  exit 1
}
rg -a -Fq \
  'ydotool is disabled on Wayland; a consented XDG Remote Desktop portal session is required' \
  "$computer_use_backend" || {
  printf 'smoke-wayland: Computer Use backend is missing the portal-only Wayland guard\n' >&2
  exit 1
}
computer_use_doctor=$(
  XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    "$launcher" computer-use-doctor
)
python3 - "$computer_use_doctor" <<'PY'
import json
import sys

report = json.loads(sys.argv[1])
readiness = report["readiness"]
assert report["platform"]["os"] == "linux"
assert report["platform"]["xdg_session_type"] == "wayland"
assert report["capabilities"]["preferred"]["input"] == "portal"
assert report["capabilities"]["preferred"]["screenshot"] == "portal"
assert report["capabilities"]["preferred"]["window_control"] != "none"
if report["platform"]["desktop_session"] == "plasma":
    assert report["capabilities"]["preferred"]["window_control"] == "kwin"
assert readiness["can_register_mcp_tools"] is True
assert readiness["can_build_accessibility_tree"] is True
assert readiness["can_query_windows"] is True
assert readiness["can_focus_windows"] is True
assert readiness["can_send_development_input"] is True
assert readiness["blockers"] == []
assert report["portals"]["remote_desktop"]["ok"] is True
assert report["portals"]["screencast"]["ok"] is True
assert report["portals"]["screenshot"]["ok"] is True
PY

python3 - "$computer_use_backend" <<'PY'
import json
import select
import subprocess
import sys
import time

backend = sys.argv[1]
process = subprocess.Popen(
    [backend, "mcp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)
assert process.stdin is not None
assert process.stdout is not None

def send(message):
    process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    process.stdin.flush()

def receive(response_id, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
        if not ready:
            break
        line = process.stdout.readline()
        if not line:
            break
        message = json.loads(line)
        if message.get("id") == response_id:
            return message
    raise RuntimeError(f"Computer Use MCP response {response_id} timed out")

try:
    send({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "chatgpt-work-wayland-smoke", "version": "1"},
        },
    })
    initialized = receive(1)
    assert "result" in initialized, initialized
    send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    tools = receive(2)["result"]["tools"]
    names = {tool["name"] for tool in tools}
    required = {
        "activate_window", "click", "doctor", "get_app_state", "press_key",
        "screenshot", "scroll", "type_text",
    }
    assert required <= names, sorted(required - names)
finally:
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)
PY

env -u DISPLAY \
  CODEX_OZONE_PLATFORM=wayland \
  CHATGPT_WORK_CODEX_HOME="$temporary/data/codex-home" \
  XDG_SESSION_TYPE=wayland \
  XDG_RUNTIME_DIR="$temporary/runtime" \
  XDG_CONFIG_HOME="$temporary/config" \
  XDG_DATA_HOME="$temporary/data" \
  XDG_CACHE_HOME="$temporary/cache" \
  XDG_STATE_HOME="$temporary/state" \
  "$launcher" >"$temporary/launcher.out" 2>&1 &
launcher_pid=$!

pid_file="$temporary/state/chatgpt-work-linux/app.pid"
for _ in {1..60}; do
  electron_pid=$(cat "$pid_file" 2>/dev/null || true)
  [[ $electron_pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$electron_pid" 2>/dev/null && break
  kill -0 "$launcher_pid" 2>/dev/null || break
  sleep 0.25
done
[[ $electron_pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$electron_pid" 2>/dev/null || {
  tail -n 100 "$temporary/launcher.out" >&2 || true
  printf 'smoke-wayland: Electron did not become active\n' >&2
  exit 1
}

for _ in {1..80}; do
  renderer=$(ps -eo pid=,args= | awk -v parent="$temporary" '
    index($0, parent) && /--type=renderer/ && /--enable-sandbox/ && /--ozone-platform=wayland/ { print; exit }
  ')
  [[ -n $renderer ]] && break
  sleep 0.25
done
[[ -n ${renderer:-} ]] || {
  tail -n 120 "$temporary/launcher.out" >&2 || true
  printf 'smoke-wayland: sandboxed Wayland renderer was not observed\n' >&2
  exit 1
}

main_cmd=$(tr '\0' ' ' <"/proc/$electron_pid/cmdline")
[[ $main_cmd == *'--ozone-platform=wayland'* ]] || { printf 'smoke-wayland: main process is not native Wayland\n' >&2; exit 1; }
[[ $main_cmd != *'--no-sandbox'* && $main_cmd != *'--disable-gpu-sandbox'* ]] || {
  printf 'smoke-wayland: main process contains a sandbox bypass\n' >&2
  exit 1
}
pgrep -af "webview-server.py.*$temporary|http.server.*$temporary" >/dev/null && {
  printf 'smoke-wayland: local webview server was started\n' >&2
  exit 1
}

log_file="$temporary/cache/chatgpt-work-linux/launcher.log"
for _ in {1..40}; do
  [[ -f $log_file ]] && rg -q 'window ready-to-show appearance=primary' "$log_file" && break
  sleep 0.25
done
rg -q 'Launching app .*packaged=true platform=linux' "$log_file" || {
  tail -n 120 "$log_file" >&2 || true
  printf 'smoke-wayland: Electron did not enter packaged mode\n' >&2
  exit 1
}
rg -q 'initialize_handshake_result .*outcome=success' "$log_file" || {
  printf 'smoke-wayland: app-server handshake did not succeed\n' >&2
  exit 1
}
! rg -q 'Failed to load URL: http://localhost|ERR_CONNECTION_REFUSED' "$log_file" || {
  printf 'smoke-wayland: renderer fell back to localhost\n' >&2
  exit 1
}

printf 'wayland_smoke=passed electron_pid=%s renderer_origin=app:// sandbox=enabled computer_use=ready\n' "$electron_pid"
