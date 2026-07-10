#!/usr/bin/env bash
set -euo pipefail

binary=${1:-/usr/bin/chatgpt-work-linux}
case $binary in
  /*) ;;
  *) binary=$(realpath -- "$binary") ;;
esac
if [[ ! -x $binary ]]; then
  printf 'smoke-wayland: binary is not executable: %s\n' "$binary" >&2
  exit 2
fi
if [[ ${XDG_SESSION_TYPE:-} != wayland || -z ${WAYLAND_DISPLAY:-} ]]; then
  printf 'smoke-wayland: an active Wayland desktop session is required\n' >&2
  exit 2
fi

for command in systemd-run systemctl busctl ps date od tr; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'smoke-wayland: missing command: %s\n' "$command" >&2
    exit 2
  }
done

profile="smoke-$$"
profile_hex=$(printf '%s' "$profile" | od -An -tx1 | tr -d ' \n')
application_id="io.github.chatgpt_work_linux.profile_$profile_hex.private"
unit="chatgpt-work-linux-$profile.service"
temporary=$(mktemp -d -t chatgpt-work-linux-wayland.XXXXXX)
main_pid=

cleanup() {
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
  rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$temporary/config" "$temporary/data" "$temporary/cache" "$temporary/state"

systemd-run --user \
  --unit="$unit" \
  --collect \
  --property=MemoryMax=768M \
  --property=CPUQuota=100% \
  --setenv=GDK_BACKEND=wayland \
  --setenv=CHATGPT_WORK_LINUX_DISABLE_SHORTCUT=1 \
  --setenv="XDG_CONFIG_HOME=$temporary/config" \
  --setenv="XDG_DATA_HOME=$temporary/data" \
  --setenv="XDG_CACHE_HOME=$temporary/cache" \
  --setenv="XDG_STATE_HOME=$temporary/state" \
  env -u DISPLAY "$binary" --profile "$profile" --private --safe-mode >/dev/null

for _ in {1..40}; do
  main_pid=$(systemctl --user show "$unit" --property=MainPID --value)
  if [[ $main_pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$main_pid" 2>/dev/null; then
    break
  fi
  sleep 0.25
done
if [[ ! $main_pid =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$main_pid" 2>/dev/null; then
  journalctl --user -u "$unit" --no-pager -n 80 >&2 || true
  printf 'smoke-wayland: application did not become active\n' >&2
  exit 1
fi

# Give the remote page a bounded interval to create both WebKit subprocesses.
for _ in {1..40}; do
  children=$(ps --ppid "$main_pid" -o args= 2>/dev/null || true)
  if grep -q 'WebKitNetworkProcess' <<<"$children" && grep -q 'WebKitWebProcess' <<<"$children"; then
    break
  fi
  sleep 0.25
done
children=$(ps --ppid "$main_pid" -o args= 2>/dev/null || true)
grep -q 'WebKitNetworkProcess' <<<"$children" || {
  printf 'smoke-wayland: WebKit network process was not created\n' >&2
  exit 1
}
grep -q 'WebKitWebProcess' <<<"$children" || {
  printf 'smoke-wayland: WebKit web process was not created\n' >&2
  exit 1
}

busctl --user --no-pager list \
  | grep -q "^$application_id[[:space:]]" || {
    printf 'smoke-wayland: profile-scoped GApplication name is missing\n' >&2
    exit 1
  }

toggle() {
  local start end elapsed output
  start=$(date +%s%N)
  output=$(env -u DISPLAY \
    GDK_BACKEND=wayland \
    CHATGPT_WORK_LINUX_DISABLE_SHORTCUT=1 \
    XDG_CONFIG_HOME="$temporary/config" \
    XDG_DATA_HOME="$temporary/data" \
    XDG_CACHE_HOME="$temporary/cache" \
    XDG_STATE_HOME="$temporary/state" \
    "$binary" --profile "$profile" --private --toggle 2>&1)
  if [[ -n $output ]]; then
    printf 'smoke-wayland: toggle produced unexpected output: %s\n' "$output" >&2
    exit 1
  fi
  end=$(date +%s%N)
  elapsed=$(( (end - start) / 1000000 ))
  if (( elapsed > 2000 )); then
    printf 'smoke-wayland: single-instance toggle took %d ms\n' "$elapsed" >&2
    exit 1
  fi
  printf '%d' "$elapsed"
}

toggle_hide_ms=$(toggle)
toggle_show_ms=$(toggle)
memory_current=$(systemctl --user show "$unit" --property=MemoryCurrent --value)
memory_peak=$(systemctl --user show "$unit" --property=MemoryPeak --value)
if [[ ! $memory_current =~ ^[0-9]+$ ]] || (( memory_current > 768 * 1024 * 1024 )); then
  printf 'smoke-wayland: invalid or excessive cgroup memory reading: %s\n' "$memory_current" >&2
  exit 1
fi

if journalctl --user -u "$unit" --no-pager \
  | grep -Eiq '(^|[[:space:]])(ERROR|CRITICAL)([[:space:]]|$)'; then
  journalctl --user -u "$unit" --no-pager -n 80 >&2
  printf 'smoke-wayland: runtime logged an error or critical failure\n' >&2
  exit 1
fi

systemctl --user stop "$unit" >/dev/null
for _ in {1..20}; do
  kill -0 "$main_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$main_pid" 2>/dev/null; then
  printf 'smoke-wayland: process remained after unit shutdown: %s\n' "$main_pid" >&2
  exit 1
fi

rm -rf -- "$temporary"
trap - EXIT HUP INT TERM
printf 'wayland_smoke=passed pid=%s toggle_hide_ms=%s toggle_show_ms=%s memory_current=%s memory_peak=%s\n' \
  "$main_pid" "$toggle_hide_ms" "$toggle_show_ms" "$memory_current" "$memory_peak"
