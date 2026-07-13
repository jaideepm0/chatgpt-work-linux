#!/usr/bin/env python3
"""Turn the generated compatibility launcher into the isolated Work runtime."""

from __future__ import annotations

import argparse
import os
from pathlib import Path


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"configure-work-runtime: expected one {label}, found {count}")
    return source.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("launcher", type=Path)
    parser.add_argument("--upstream-version", required=True)
    args = parser.parse_args()

    launcher = args.launcher
    source = launcher.read_text(encoding="utf-8")
    prelude_anchor = "CODEX_LINUX_WEBVIEW_PORT=${CODEX_WEBVIEW_PORT:-5176}\n"
    prelude = f"""{prelude_anchor}CODEX_LINUX_DESKTOP_ID=io.github.chatgpt_work_linux
CODEX_LINUX_EXECUTABLE_NAME=chatgpt-work-linux-bin
CODEX_OZONE_PLATFORM=wayland
CHATGPT_WORK_UPSTREAM_VERSION={args.upstream_version}

case ${{1:-}} in
  doctor)
    wayland_session=false
    if [[ ${{XDG_SESSION_TYPE:-}} == wayland && -n ${{WAYLAND_DISPLAY:-}} ]]; then
      wayland_session=true
    fi
    if [[ ${{2:-}} == --json ]]; then
      printf '{{\"application\":\"chatgpt-work-linux\",\"unofficial\":true,\"runtime\":\"electron\",\"upstreamVersion\":\"%s\",\"electronVersion\":\"%s\",\"waylandSession\":%s,\"sandboxDisabled\":false,\"rendererOrigin\":\"app://\",\"profile\":\"isolated-xdg\"}}\\n' \\
        "$CHATGPT_WORK_UPSTREAM_VERSION" "$(cat \"$(dirname -- \"$(readlink -f -- \"${{BASH_SOURCE[0]}}\")\")/version\" 2>/dev/null || printf unknown)" "$wayland_session"
    else
      printf 'ChatGPT Work Linux (Unofficial)\\n  Runtime: Electron, packaged app:// renderer\\n  Upstream: %s\\n  Wayland: required\\n  Chromium sandbox disabled: false\\n  Profile: isolated XDG state\\n' "$CHATGPT_WORK_UPSTREAM_VERSION"
    fi
    exit 0
    ;;
esac
"""
    source = replace_once(source, prelude_anchor, prelude, "identity prelude")
    source = replace_once(
        source,
        "CODEX_LINUX_APP_ID=io.github.chatgpt_work_linux\n",
        "CODEX_LINUX_APP_ID=chatgpt-work-linux\n",
        "runtime profile identity",
    )
    source = source.replace("$SCRIPT_DIR/electron", "$SCRIPT_DIR/$CODEX_LINUX_EXECUTABLE_NAME")

    old_home = """if [ -z "${CODEX_HOME:-}" ]; then
    if [ -n "${HOME:-}" ]; then
        CODEX_HOME="$HOME/.codex"
    else
        CODEX_HOME=""
    fi
fi
"""
    new_home = """if [ -n "${CHATGPT_WORK_CODEX_HOME:-}" ]; then
    CODEX_HOME="$CHATGPT_WORK_CODEX_HOME"
elif [ -n "${HOME:-}" ]; then
    CODEX_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/$CODEX_LINUX_APP_ID/codex-home"
else
    CODEX_HOME=""
fi
"""
    source = replace_once(source, old_home, new_home, "isolated CODEX_HOME block")
    source = replace_once(
        source,
        "export CODEX_HOME CODEX_LINUX_APP_ID CODEX_LINUX_APP_DISPLAY_NAME",
        "export CODEX_HOME CODEX_LINUX_APP_ID CODEX_LINUX_DESKTOP_ID CODEX_LINUX_EXECUTABLE_NAME CODEX_LINUX_APP_DISPLAY_NAME",
        "runtime identity export",
    )
    source = replace_once(
        source,
        'APP_NOTIFICATION_ICON_NAME="$CODEX_LINUX_APP_ID"',
        'APP_NOTIFICATION_ICON_NAME="$CODEX_LINUX_DESKTOP_ID"',
        "notification identity",
    )
    source = source.replace("$CODEX_LINUX_APP_ID.desktop", "$CODEX_LINUX_DESKTOP_ID.desktop")
    source = source.replace("--app-id=$CODEX_LINUX_APP_ID", "--app-id=$CODEX_LINUX_DESKTOP_ID")

    sandbox_args = """    ELECTRON_LAUNCH_ARGS=(
        --no-sandbox
        --class="$CODEX_LINUX_APP_ID"
        --app-id="$CODEX_LINUX_APP_ID"
        --disable-gpu-sandbox
    )
"""
    safe_args = """    ELECTRON_LAUNCH_ARGS=(
        --class="$CODEX_LINUX_DESKTOP_ID"
        --app-id="$CODEX_LINUX_DESKTOP_ID"
    )
"""
    source = replace_once(source, sandbox_args, safe_args, "sandbox launch arguments")
    source = replace_once(
        source,
        "    run_packaged_runtime_prelaunch\n    log_phase \"packaged_prelaunch\"\n    start_webview_server\n",
        "    run_packaged_runtime_prelaunch\n    log_phase \"packaged_prelaunch\"\n    echo \"Using packaged app:// renderer\"\n",
        "webview startup call",
    )

    renderer_block = """if ! truthy_env_value "${CODEX_LINUX_ALLOW_RENDERER_URL_OVERRIDE:-}"; then
    if [ -n "${ELECTRON_RENDERER_URL:-}" ] && [ "$ELECTRON_RENDERER_URL" != "$WEBVIEW_ORIGIN/" ]; then
        echo "Ignoring inherited ELECTRON_RENDERER_URL; set CODEX_LINUX_ALLOW_RENDERER_URL_OVERRIDE=1 to allow overrides"
    fi
    export ELECTRON_RENDERER_URL="$WEBVIEW_ORIGIN/"
else
    export ELECTRON_RENDERER_URL="${ELECTRON_RENDERER_URL:-$WEBVIEW_ORIGIN/}"
fi
"""
    source = replace_once(
        source,
        renderer_block,
        "# Production Work builds use Electron's packaged app:// protocol.\nunset ELECTRON_RENDERER_URL\n",
        "renderer origin block",
    )
    source = replace_once(
        source,
        "    await_webview_server_ready\nfi\nresolve_browser_use_runtime_env",
        "    : # packaged app:// renderer needs no local server readiness probe\nfi\nresolve_browser_use_runtime_env",
        "webview readiness call",
    )
    source = replace_once(
        source,
        '    exec >>"$LOG_FILE" 2>&1\n',
        '    if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE" 2>/dev/null || printf 0)" -gt 1048576 ]; then\n'
        '        tail -c 262144 "$LOG_FILE" >"$LOG_FILE.trim" && mv -f "$LOG_FILE.trim" "$LOG_FILE"\n'
        '    fi\n'
        '    exec >>"$LOG_FILE" 2>&1\n',
        "bounded launcher log",
    )

    temporary = launcher.with_name(f".{launcher.name}.new-{os.getpid()}")
    temporary.write_text(source, encoding="utf-8")
    os.chmod(temporary, launcher.stat().st_mode)
    os.replace(temporary, launcher)


if __name__ == "__main__":
    main()
