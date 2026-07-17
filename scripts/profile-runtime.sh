#!/usr/bin/env bash
set -euo pipefail

launcher=${1:-"$HOME/.local/bin/chatgpt-work-linux"}
settle_seconds=${CHATGPT_WORK_PROFILE_SETTLE_SECONDS:-30}
[[ $launcher == /* ]] || launcher=$(realpath -- "$launcher")
[[ -x $launcher ]] || { printf 'profile-runtime: launcher is not executable: %s\n' "$launcher" >&2; exit 2; }
[[ ${XDG_SESSION_TYPE:-} == wayland && -n ${WAYLAND_DISPLAY:-} ]] || {
  printf 'profile-runtime: an active Wayland session is required\n' >&2
  exit 2
}
[[ $settle_seconds =~ ^[1-9][0-9]*$ ]] || {
  printf 'profile-runtime: settle time must be a positive integer\n' >&2
  exit 2
}

temporary=$(mktemp -d -t chatgpt-work-profile.XXXXXX)
session_runtime=${XDG_RUNTIME_DIR:?profile-runtime: XDG_RUNTIME_DIR is required}
launcher_pid=
electron_pid=
mkdir -m 0700 -- "$temporary/runtime"
ln -s -- "$session_runtime/$WAYLAND_DISPLAY" "$temporary/runtime/$WAYLAND_DISPLAY"
mkdir -p -- "$temporary/config" "$temporary/data" "$temporary/cache" "$temporary/state"

# Benchmark the actual signed-in UI without sharing mutable state with the
# running desktop. Seed only bounded startup-relevant state: copying the full
# canonical home would duplicate sessions and worktrees and distort the
# measurement. CI and signed-out systems simply exercise the unseeded path.
seed_codex_home=${CHATGPT_WORK_PROFILE_SEED_CODEX_HOME:-"${CODEX_HOME:-$HOME/.codex}"}
if [[ -d $seed_codex_home ]]; then
  mkdir -p -- "$temporary/data/codex-home"
  for seed_file in auth.json config.toml .codex-global-state.json installation_id models_cache.json; do
    [[ ! -f $seed_codex_home/$seed_file ]] || \
      cp -a --reflink=auto "$seed_codex_home/$seed_file" "$temporary/data/codex-home/$seed_file"
  done
  for seed_directory in cache plugins skills vendor_imports; do
    [[ ! -d $seed_codex_home/$seed_directory ]] || \
      cp -a --reflink=auto "$seed_codex_home/$seed_directory" "$temporary/data/codex-home/$seed_directory"
  done
  if [[ -f $seed_codex_home/state_5.sqlite ]] && command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$seed_codex_home/state_5.sqlite" \
      ".timeout 30000" \
      ".backup '$temporary/data/codex-home/state_5.sqlite'"
  fi
  find "$temporary/data/codex-home" -type f \
    \( -name '*.lock' -o -name app-server-startup.lock \) -delete
  find "$temporary/data/codex-home" -type l -name 'Singleton*' -delete
  rm -f -- "$temporary/data/codex-home/process_manager/chat_processes.json"
fi
seed_state=${CHATGPT_WORK_PROFILE_SEED_STATE:-"${XDG_STATE_HOME:-$HOME/.local/state}/chatgpt-work-linux"}
if [[ -d $seed_state ]]; then
  mkdir -p -- "$temporary/state/chatgpt-work-linux"
  cp -a --reflink=auto "$seed_state/." "$temporary/state/chatgpt-work-linux/"
  find "$temporary/state/chatgpt-work-linux" -type f \
    \( -name app.pid -o -name launcher.lock -o -name instance.lock \) -delete
  find "$temporary/state/chatgpt-work-linux" -type l -name 'Singleton*' -delete
fi
seed_config=${CHATGPT_WORK_PROFILE_SEED_CONFIG:-"${XDG_CONFIG_HOME:-$HOME/.config}/chatgpt-work-linux"}
if [[ -d $seed_config ]]; then
  mkdir -p -- "$temporary/config/chatgpt-work-linux"
  cp -a --reflink=auto "$seed_config/." "$temporary/config/chatgpt-work-linux/"
fi

cpu_set=$(python3 - <<'PY'
allowed = ""
with open("/proc/self/status", encoding="utf-8") as handle:
    for line in handle:
        if line.startswith("Cpus_allowed_list:"):
            allowed = line.split(":", 1)[1].strip()
            break
cpus = []
for part in allowed.split(","):
    if not part:
        continue
    if "-" in part:
        start, end = map(int, part.split("-", 1))
        cpus.extend(range(start, end + 1))
    else:
        cpus.append(int(part))
print(",".join(map(str, cpus[:2])))
PY
)
[[ -n $cpu_set ]] || { printf 'profile-runtime: no permitted CPUs found\n' >&2; exit 1; }

tree_pids() {
  local root=$1
  python3 - "$root" <<'PY'
import os
import sys
root = int(sys.argv[1])
parents = {}
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    try:
        stat = open(f"/proc/{name}/stat", encoding="utf-8").read()
        tail = stat.rsplit(")", 1)[1].split()
        parents[int(name)] = int(tail[1])
    except (FileNotFoundError, PermissionError, ValueError, IndexError):
        pass
selected = {root}
changed = True
while changed:
    changed = False
    for pid, ppid in parents.items():
        if ppid in selected and pid not in selected:
            selected.add(pid)
            changed = True
print(" ".join(map(str, sorted(selected))))
PY
}

memory_kib() {
  local root=$1 pids pid pss=0 rss=0 value
  pids=$(tree_pids "$root")
  for pid in $pids; do
    if [[ -r /proc/$pid/smaps_rollup ]]; then
      value=$(awk '/^Pss:/ {print $2; exit}' "/proc/$pid/smaps_rollup" 2>/dev/null || printf 0)
      pss=$((pss + value))
    fi
    if [[ -r /proc/$pid/status ]]; then
      value=$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null || printf 0)
      rss=$((rss + value))
    fi
  done
  printf '%s %s %s\n' "$pss" "$rss" "$(wc -w <<<"$pids")"
}

cpu_ticks() {
  local root=$1 pids pid total=0
  pids=$(tree_pids "$root")
  for pid in $pids; do
    [[ -r /proc/$pid/stat ]] || continue
    total=$((total + $(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || printf 0)))
  done
  printf '%s\n' "$total"
}

profile_related_pids() {
  python3 - "$temporary" <<'PY'
import os
import sys
needle = os.fsencode(sys.argv[1])
for name in os.listdir("/proc"):
    if not name.isdigit() or int(name) == os.getpid():
        continue
    try:
        command = open(f"/proc/{name}/cmdline", "rb").read()
    except (FileNotFoundError, PermissionError):
        continue
    if needle in command:
        print(name)
PY
}

stop_profile_processes() {
  local pids=""
  if [[ ${electron_pid:-} =~ ^[1-9][0-9]*$ ]]; then
    pids=$(tree_pids "$electron_pid" 2>/dev/null || true)
  fi
  pids=$(printf '%s\n%s\n%s\n' "$pids" "${launcher_pid:-}" "$(profile_related_pids)" |
    tr ' ' '\n' | awk '/^[1-9][0-9]*$/' | sort -un | tr '\n' ' ')
  [[ -z $pids ]] || kill $pids 2>/dev/null || true
  for _ in {1..30}; do
    remaining=$(profile_related_pids | tr '\n' ' ')
    [[ -z $remaining ]] && break
    sleep 0.1
  done
  remaining=$(profile_related_pids | tr '\n' ' ')
  [[ -z $remaining ]] || kill -KILL $remaining 2>/dev/null || true
  launcher_pid=
  electron_pid=
}

cleanup() {
  stop_profile_processes
  [[ ! -e $temporary ]] || find "$temporary" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

launch_profile() {
  env -u DISPLAY \
    CODEX_OZONE_PLATFORM=wayland \
    CHATGPT_WORK_CODEX_HOME="$temporary/data/codex-home" \
    XDG_SESSION_TYPE=wayland \
    XDG_RUNTIME_DIR="$temporary/runtime" \
    XDG_CONFIG_HOME="$temporary/config" \
    XDG_DATA_HOME="$temporary/data" \
    XDG_CACHE_HOME="$temporary/cache" \
    XDG_STATE_HOME="$temporary/state" \
    taskset -c "$cpu_set" "$launcher" >"$temporary/launcher.out" 2>&1 &
  launcher_pid=$!
}

start_ns=$(date +%s%N)
launch_profile

pid_file="$temporary/state/chatgpt-work-linux/app.pid"
peak_pss=0
ready=0
for _ in {1..180}; do
  electron_pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ $electron_pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$electron_pid" 2>/dev/null; then
    log_file="$temporary/cache/chatgpt-work-linux/launcher.log"
    if [[ -f $log_file ]] && rg -q 'window ready-to-show appearance=primary' "$log_file"; then
      ready=1
      break
    fi
  fi
  kill -0 "$launcher_pid" 2>/dev/null || break
  sleep 0.25
done
if [[ $ready -ne 1 ]]; then
  tail -n 120 "$temporary/launcher.out" >&2 || true
  [[ -z ${log_file:-} ]] || tail -n 120 "$log_file" >&2 || true
  printf 'profile-runtime: application did not become ready\n' >&2
  exit 1
fi
ready_ns=$(date +%s%N)
read -r cold_ready_pss _ _ < <(memory_kib "$electron_pid")
(( cold_ready_pss > peak_pss )) && peak_pss=$cold_ready_pss
cold_start_ns=$start_ns
cold_ready_ns=$ready_ns
cold_peak_pss=$peak_pss

# Relaunch on the same isolated profile. This separates one-time plugin,
# account, and catalog initialization from steady-state resource usage.
sleep 2
stop_profile_processes
find "$temporary/state" -type f \( -name app.pid -o -name launcher.lock \) -delete 2>/dev/null || true
find "$temporary/state" -type l -name 'Singleton*' -delete 2>/dev/null || true
: >"$temporary/launcher.out"
log_file="$temporary/cache/chatgpt-work-linux/launcher.log"
[[ ! -e $log_file ]] || : >"$log_file"

start_ns=$(date +%s%N)
launch_profile
peak_pss=0
ready=0
electron_pid=
for _ in {1..180}; do
  electron_pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ $electron_pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$electron_pid" 2>/dev/null; then
    if [[ -f $log_file ]] && rg -q 'window ready-to-show appearance=primary' "$log_file"; then
      ready=1
      break
    fi
  fi
  kill -0 "$launcher_pid" 2>/dev/null || break
  sleep 0.25
done
if [[ $ready -ne 1 ]]; then
  tail -n 120 "$temporary/launcher.out" >&2 || true
  tail -n 120 "$log_file" >&2 || true
  printf 'profile-runtime: warm application launch did not become ready\n' >&2
  exit 1
fi
ready_ns=$(date +%s%N)
read -r warm_ready_pss _ _ < <(memory_kib "$electron_pid")
(( warm_ready_pss > peak_pss )) && peak_pss=$warm_ready_pss

# Measure the actual warm-start path while this second process tree remains
# active. The handoff must reuse the same Electron main process and avoid a
# second renderer/app-server tree.
launch_socket="$temporary/runtime/chatgpt-work-linux/launch-action.sock"
for _ in {1..40}; do
  [[ -S $launch_socket ]] && break
  sleep 0.1
done
[[ -S $launch_socket ]] || {
  printf 'profile-runtime: warm-start launch-action socket was not created\n' >&2
  exit 1
}
warm_handoff_start_ns=$(date +%s%N)
timeout 10 env -u DISPLAY \
  CODEX_OZONE_PLATFORM=wayland \
  CHATGPT_WORK_CODEX_HOME="$temporary/data/codex-home" \
  XDG_SESSION_TYPE=wayland \
  XDG_RUNTIME_DIR="$temporary/runtime" \
  XDG_CONFIG_HOME="$temporary/config" \
  XDG_DATA_HOME="$temporary/data" \
  XDG_CACHE_HOME="$temporary/cache" \
  XDG_STATE_HOME="$temporary/state" \
  taskset -c "$cpu_set" "$launcher" --new-chat >"$temporary/warm-handoff.out" 2>&1
warm_handoff_end_ns=$(date +%s%N)
[[ $(<"$pid_file") == "$electron_pid" ]] && kill -0 "$electron_pid" 2>/dev/null || {
  printf 'profile-runtime: warm handoff replaced the active Electron process\n' >&2
  exit 1
}
rg -q 'Sent launch args over warm-start IPC' "$log_file" || {
  printf 'profile-runtime: warm handoff did not use IPC\n' >&2
  exit 1
}

# Allow authentication, catalog sync, and first-render work to quiesce before
# measuring idle CPU and settled memory.
settle_samples=$settle_seconds
for ((sample = 0; sample < settle_samples; sample++)); do
  read -r current_pss _ _ < <(memory_kib "$electron_pid")
  (( current_pss > peak_pss )) && peak_pss=$current_pss
  sleep 1
done
read -r settled_pss settled_rss process_count < <(memory_kib "$electron_pid")
(( settled_pss > peak_pss )) && peak_pss=$settled_pss

ticks_before=$(cpu_ticks "$electron_pid")
declare -A process_ticks_before=()
if [[ ${CHATGPT_WORK_PROFILE_PROCESS_DETAILS:-0} == 1 ]]; then
  for pid in $(tree_pids "$electron_pid"); do
    [[ -r /proc/$pid/stat ]] || continue
    process_ticks_before[$pid]=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || printf 0)
  done
fi
cpu_start_ns=$(date +%s%N)
sleep 4
ticks_after=$(cpu_ticks "$electron_pid")
cpu_end_ns=$(date +%s%N)
clock_ticks=$(getconf CLK_TCK)

python3 - "$cold_start_ns" "$cold_ready_ns" "$cold_peak_pss" \
  "$start_ns" "$ready_ns" "$settled_pss" "$settled_rss" "$peak_pss" \
  "$process_count" "$ticks_before" "$ticks_after" "$cpu_start_ns" "$cpu_end_ns" \
  "$clock_ticks" "$cpu_set" "$warm_handoff_start_ns" "$warm_handoff_end_ns" <<'PY'
import sys
(cold_start, cold_ready, cold_peak, start, ready, pss, rss, peak, processes,
 ticks0, ticks1, cpu0, cpu1, hz, cpus, handoff_start, handoff_end) = sys.argv[1:]
cold_launch = (int(cold_ready) - int(cold_start)) / 1e9
warm_launch = (int(ready) - int(start)) / 1e9
warm_handoff = (int(handoff_end) - int(handoff_start)) / 1e9
wall = (int(cpu1) - int(cpu0)) / 1e9
cpu = ((int(ticks1) - int(ticks0)) / int(hz)) / wall * 100 if wall else 0
print(f"cold_launch_to_ready_seconds={cold_launch:.3f}")
print(f"warm_launch_to_ready_seconds={warm_launch:.3f}")
print(f"warm_handoff_seconds={warm_handoff:.3f}")
print(f"cpu_set={cpus}")
print(f"process_count={processes}")
print(f"settled_pss_mib={int(pss) / 1024:.1f}")
print(f"settled_rss_mib={int(rss) / 1024:.1f}")
print(f"cold_peak_pss_mib={int(cold_peak) / 1024:.1f}")
print(f"peak_pss_mib={int(peak) / 1024:.1f}")
print(f"settled_cpu_percent={cpu:.2f}")
PY

if [[ ${CHATGPT_WORK_PROFILE_PROCESS_DETAILS:-0} == 1 ]]; then
  printf 'processes:\n'
  for pid in $(tree_pids "$electron_pid"); do
    [[ -r /proc/$pid/status ]] || continue
    rss=$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status")
    ticks=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || printf 0)
    before=${process_ticks_before[$pid]:-$ticks}
    cpu=$(awk -v delta="$((ticks - before))" -v hz="$clock_ticks" \
      -v wall_ns="$((cpu_end_ns - cpu_start_ns))" \
      'BEGIN { if (wall_ns > 0) printf "%.2f", (delta / hz) / (wall_ns / 1000000000) * 100; else print "0.00" }')
    printf '%8s %7s%% %10s KiB %s\n' "$pid" "$cpu" "${rss:-0}" "$(tr '\0' ' ' <"/proc/$pid/cmdline")"
  done
fi
