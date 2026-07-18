#!/usr/bin/env python3
"""Turn the generated compatibility launcher into the hardened Work runtime."""

from __future__ import annotations

import argparse
import os
from pathlib import Path


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"configure-work-runtime: expected one {label}, found {count}")
    return source.replace(old, new, 1)


def replace_section(
    source: str,
    start_anchor: str,
    end_anchor: str,
    replacement: str,
    label: str,
    required_fragments: tuple[str, ...],
) -> str:
    """Replace one reviewed launcher section while failing closed on drift."""
    start_count = source.count(start_anchor)
    end_count = source.count(end_anchor)
    if start_count != 1 or end_count != 1:
        raise SystemExit(
            f"configure-work-runtime: expected one {label} boundary, "
            f"found start={start_count} end={end_count}"
        )
    start = source.index(start_anchor)
    end = source.index(end_anchor, start)
    section = source[start:end]
    for fragment in required_fragments:
        count = section.count(fragment)
        if count != 1:
            raise SystemExit(
                f"configure-work-runtime: expected one {label} fragment "
                f"{fragment!r}, found {count}"
            )
    return source[:start] + replacement + source[end:]


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

# Native Wayland GPU compositing measured dramatically lower settled CPU and
# memory on the target system. Keep the adapter workaround as an explicit
# fallback for compositors that exhibit transparent or flickering side panels.
if [[ -z ${{CODEX_ELECTRON_DISABLE_GPU_COMPOSITING+x}} ]]; then
  CODEX_ELECTRON_DISABLE_GPU_COMPOSITING=0
fi
# KDE exposes an AT-SPI bus even when no assistive Chromium client is active.
# Do not force every renderer accessibility tree for that ambient bus alone;
# screen-reader users can explicitly set this back to 1.
if [[ -z ${{CODEX_FORCE_RENDERER_ACCESSIBILITY+x}} ]]; then
  CODEX_FORCE_RENDERER_ACCESSIBILITY=0
fi

case ${{1:-}} in
  doctor)
    wayland_session=false
    if [[ ${{XDG_SESSION_TYPE:-}} == wayland && -n ${{WAYLAND_DISPLAY:-}} ]]; then
      wayland_session=true
    fi
    if [[ ${{2:-}} == --json ]]; then
      printf '{{\"application\":\"chatgpt-work-linux\",\"unofficial\":true,\"runtime\":\"electron\",\"upstreamVersion\":\"%s\",\"electronVersion\":\"%s\",\"waylandSession\":%s,\"sandboxDisabled\":false,\"rendererOrigin\":\"app://\",\"profile\":\"xdg-electron+canonical-codex\"}}\\n' \\
        "$CHATGPT_WORK_UPSTREAM_VERSION" "$(cat \"$(dirname -- \"$(readlink -f -- \"${{BASH_SOURCE[0]}}\")\")/version\" 2>/dev/null || printf unknown)" "$wayland_session"
    else
      printf 'ChatGPT Work Linux (Unofficial)\\n  Runtime: Electron, packaged app:// renderer\\n  Upstream: %s\\n  Wayland: required\\n  Chromium sandbox disabled: false\\n  Profile: isolated XDG Electron state + canonical Codex home\\n' "$CHATGPT_WORK_UPSTREAM_VERSION"
    fi
    exit 0
    ;;
  computer-use-doctor|computer-use-setup)
    runtime_root=$(dirname -- "$(readlink -f -- "${{BASH_SOURCE[0]}}")")
    computer_use_backend="$runtime_root/resources/plugins/openai-bundled/plugins/computer-use/bin/codex-computer-use-linux"
    if [[ ! -x $computer_use_backend ]]; then
      printf 'ChatGPT Work Linux: Computer Use backend is missing or not executable: %s\n' "$computer_use_backend" >&2
      exit 1
    fi
    if [[ ${{1:-}} == computer-use-doctor ]]; then
      exec "$computer_use_backend" doctor
    fi
    exec "$computer_use_backend" setup
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
elif [ -z "${CODEX_HOME:-}" ]; then
    if [ -n "${HOME:-}" ]; then
        CODEX_HOME="$HOME/.codex"
    else
        CODEX_HOME=""
    fi
fi
"""
    source = replace_once(source, old_home, new_home, "canonical CODEX_HOME block")
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
        --force-prefers-reduced-motion
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
    source = replace_section(
        source,
        "recover_unhealthy_running_app() {\n",
        "send_warm_start_launch_action() {\n",
        """recover_unhealthy_running_app() {
    running_app_is_active || return 0

    if [ -S "$LAUNCH_ACTION_SOCKET" ]; then
        return 0
    fi

    # A verified packaged app:// process does not have a localhost renderer to
    # probe. Preserve it and use Electron's native second-instance handoff if
    # the optional launch-action socket is absent or still being established.
    echo "Running packaged app:// Electron pid=$RUNNING_APP_PID has no launch-action socket; preserving it for Electron second-instance handoff"
    WARM_START=0
}

""",
        "packaged app recovery",
        (
            "webview_origin_is_reachable && return 0",
            "terminate_stale_electron_with_pidfd",
            "unavailable packaged webview origin",
        ),
    )
    warm_default = 'linux_setting_enabled "codex-linux-warm-start-enabled" 1'
    warm_default_count = source.count(warm_default)
    if warm_default_count != 2:
        raise SystemExit(
            "configure-work-runtime: expected two default-on warm-start "
            f"launcher checks, found {warm_default_count}"
        )
    source = source.replace(
        warm_default,
        'linux_setting_enabled "codex-linux-warm-start-enabled" 0',
    )
    source = replace_once(
        source,
        "sync_extra_bundled_plugin_cache() {\n",
        '''extra_plugin_cache_requires_rebuild() {
    local directory="$1"
    local unsafe=""
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 0
    if ! unsafe="$(find "$directory" -xdev \\
        \\( -type l -o -perm /222 \\) -print -quit 2>/dev/null)"; then
        return 0
    fi
    [ -n "$unsafe" ]
}

sync_extra_bundled_plugin_cache() {
''',
        "extra bundled plugin read-only verifier",
    )
    source = replace_once(
        source,
        '''        cache_parent="$(dirname "$cache_plugin")"
        tmp_plugin="$cache_parent/.$plugin_name-$version.tmp.$$"
''',
        '''        cache_parent="$(dirname "$cache_plugin")"
        local source_digest cache_digest

        source_digest="$(cat "$source_plugin/.chatgpt-work-source-integrity" 2>/dev/null || true)"
        cache_digest=""
        [ -z "$source_digest" ] || \\
            cache_digest="$(cat "$cache_plugin/.chatgpt-work-source-integrity" 2>/dev/null || true)"

        # Versioned plugin directories are published by an atomic rename. Reuse
        # only a complete cache whose deterministic tree digest still matches
        # the immutable bundled source. An incomplete, modified, or unsafe tree
        # is rebuilt below.
        if [ -d "$cache_plugin" ] && [ ! -L "$cache_plugin" ] && \\
           [ -f "$cache_plugin/.codex-plugin/plugin.json" ] && \\
           cmp -s "$plugin_json" "$cache_plugin/.codex-plugin/plugin.json" && \\
           [ -n "$source_digest" ] && [ "$cache_digest" = "$source_digest" ] && \\
           [ -f "$cache_plugin/.chatgpt-work-source-integrity" ] && \\
           [ "$(cat "$cache_plugin/.chatgpt-work-source-integrity" 2>/dev/null)" = "$source_digest" ] && \\
           ! path_has_unsafe_write \\
               "$SCRIPT_DIR" "$SCRIPT_DIR/resources" \\
               "$SCRIPT_DIR/resources/plugins" \\
               "$SCRIPT_DIR/resources/plugins/openai-bundled" \\
               "$SCRIPT_DIR/resources/plugins/openai-bundled/plugins" "$source_plugin" && \\
           ! tree_has_unsafe_write "$source_plugin" && \\
           ! path_has_unsafe_write \\
               "$codex_home" "$codex_home/plugins" "$codex_home/plugins/cache" \\
               "$codex_home/plugins/cache/openai-bundled" "$cache_root" && \\
           ! tree_has_unsafe_write "$cache_plugin" && \\
           ! extra_plugin_cache_requires_rebuild "$cache_plugin"; then
            marketplace_root="$codex_home/.tmp/bundled-marketplaces/openai-bundled"
            marketplace_plugins_dir="$marketplace_root/.agents/plugins"
            marketplace_plugin_link="$marketplace_root/plugins/$plugin_dir_name"
            if ! replace_symlink "$version" "$cache_root/latest" || \\
               ! mkdir -p "$marketplace_plugins_dir" "$marketplace_root/plugins" || \\
               ! replace_symlink "$cache_root/latest" "$marketplace_plugin_link"; then
                echo "Extra bundled plugin marketplace link repair failed for $plugin_name; preserving the valid cache."
            fi
            continue
        fi

        tmp_plugin="$cache_parent/.$plugin_name-$version.tmp.$$"
''',
        "extra bundled plugin cache reuse",
    )
    source = replace_once(
        source,
        '''            if ! find "$tmp_plugin" -type f -name '*:com.apple.*' -delete; then
                remove_tree_if_exists "$tmp_plugin" || true
                echo "Extra bundled plugin cache cleanup failed for $plugin_name; continuing with existing cache."
                continue
            fi
            if [ -e "$cache_plugin" ] || [ -L "$cache_plugin" ]; then
''',
        '''            if ! find "$tmp_plugin" -type f -name '*:com.apple.*' -delete; then
                remove_tree_if_exists "$tmp_plugin" || true
                echo "Extra bundled plugin cache cleanup failed for $plugin_name; continuing with existing cache."
                continue
            fi
            cache_digest="$(cat "$tmp_plugin/.chatgpt-work-source-integrity" 2>/dev/null || true)"
            if [ -z "$source_digest" ] || [ "$cache_digest" != "$source_digest" ] || \\
               ! printf '%s\\n' "$source_digest" >"$tmp_plugin/.chatgpt-work-source-integrity"; then
                remove_tree_if_exists "$tmp_plugin" || true
                echo "Extra bundled plugin cache integrity failed for $plugin_name; continuing with existing cache."
                continue
            fi
            find "$tmp_plugin" -type d -exec chmod a-w {} +
            find "$tmp_plugin" -type f -exec chmod a-w {} +
            if [ -e "$cache_plugin" ] || [ -L "$cache_plugin" ]; then
''',
        "extra bundled plugin cache integrity publication",
    )
    source = replace_once(
        source,
        '''    else
        run_cli_preflight_background
        log_phase "cli_preflight_backgrounded"
    fi
''',
        '''    else
        # Normal startup performs no registry lookup or unattended CLI update.
        # Explicit update transactions own upgrades; proven repair remains the
        # synchronous branch above.
        log_phase "cli_preflight_deferred_to_explicit_update"
    fi
''',
        "background CLI update removal",
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
