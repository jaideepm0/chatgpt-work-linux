#!/usr/bin/env bash
set -euo pipefail

launcher=${1:-"$HOME/.local/bin/chatgpt-work-linux"}
settle_seconds=${CHATGPT_WORK_PROFILE_SETTLE_SECONDS:-30}
memory_max_mib=${CHATGPT_WORK_PROFILE_MEMORY_MAX_MIB:-0}
memory_high_mib=${CHATGPT_WORK_PROFILE_MEMORY_HIGH_MIB:-0}
allow_memory_pressure=${CHATGPT_WORK_PROFILE_ALLOW_MEMORY_PRESSURE:-0}
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
[[ $memory_max_mib =~ ^[0-9]+$ && $memory_high_mib =~ ^[0-9]+$ ]] || {
  printf 'profile-runtime: memory limits must be non-negative integer MiB values\n' >&2
  exit 2
}
if (( memory_max_mib > 0 )); then
  [[ $allow_memory_pressure == 1 ]] || {
    printf '%s\n' \
      'profile-runtime: constrained profiling can invoke the kernel OOM killer.' \
      'Re-run with CHATGPT_WORK_PROFILE_ALLOW_MEMORY_PRESSURE=1 only after saving work.' >&2
    exit 2
  }
  (( memory_high_mib > 0 && memory_high_mib < memory_max_mib )) || {
    printf 'profile-runtime: MemoryHigh must be positive and below MemoryMax\n' >&2
    exit 2
  }
  command -v systemd-run >/dev/null 2>&1 || {
    printf 'profile-runtime: systemd-run is required for the constrained-memory lane\n' >&2
    exit 2
  }
  [[ -r /sys/fs/cgroup/cgroup.controllers ]] || {
    printf 'profile-runtime: unified cgroup v2 is required for the constrained-memory lane\n' >&2
    exit 2
  }
  systemctl --user show-environment >/dev/null 2>&1 || {
    printf 'profile-runtime: a running systemd user manager is required for the constrained-memory lane\n' >&2
    exit 2
  }
  host_available_mib=$(awk '/^MemAvailable:/ {print int($2 / 1024); exit}' /proc/meminfo)
  min_host_available_mib=${CHATGPT_WORK_PROFILE_MIN_AVAILABLE_MIB:-$((memory_max_mib + 1024))}
  [[ $min_host_available_mib =~ ^[1-9][0-9]*$ ]] || {
    printf 'profile-runtime: minimum host-available memory must be a positive integer MiB value\n' >&2
    exit 2
  }
  (( host_available_mib >= min_host_available_mib )) || {
    printf 'profile-runtime: refusing memory-pressure run: available=%s MiB required=%s MiB\n' \
      "$host_available_mib" "$min_host_available_mib" >&2
    exit 2
  }
fi

temporary=$(mktemp -d -t chatgpt-work-profile.XXXXXX)
session_runtime=${XDG_RUNTIME_DIR:?profile-runtime: XDG_RUNTIME_DIR is required}
launcher_pid=
electron_pid=
profile_launch_sequence=0
profile_scope_cgroup=
profile_scope_unit=
profile_runner_scope_unit=
profile_runner_scope_cgroup=
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

cpu_snapshot() {
  local root=$1 pids pid stat start_time ticks
  pids=$(tree_pids "$root")
  for pid in $pids; do
    [[ -r /proc/$pid/stat ]] || continue
    stat=$(<"/proc/$pid/stat") || continue
    start_time=$(awk '{print $22}' <<<"$stat")
    ticks=$(awk '{print $14+$15}' <<<"$stat")
    [[ $start_time =~ ^[0-9]+$ && $ticks =~ ^[0-9]+$ ]] || continue
    printf '%s:%s %s\n' "$pid" "$start_time" "$ticks"
  done
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

print_constrained_failure_diagnostics() {
  local cgroup=${profile_scope_cgroup:-$profile_runner_scope_cgroup}
  local cgroup_root pid comm role pss rss command
  (( memory_max_mib > 0 )) || return 0
  [[ -n $cgroup ]] || {
    printf 'profile-runtime: constrained diagnostics unavailable: scope was not resolved\n' >&2
    return 0
  }
  cgroup_root="/sys/fs/cgroup$cgroup"
  [[ -d $cgroup_root ]] || {
    printf 'profile-runtime: constrained diagnostics unavailable: scope has already closed\n' >&2
    return 0
  }

  printf 'profile-runtime: constrained failure diagnostics (%s):\n' "$cgroup" >&2
  for metric in memory.current memory.peak memory.swap.current memory.events memory.pressure; do
    [[ -r $cgroup_root/$metric ]] || continue
    printf '  %s:\n' "$metric" >&2
    sed -n '1,20{s/^/    /;p}' "$cgroup_root/$metric" >&2 || true
  done
  for pid in $(profile_related_pids | sort -un); do
    [[ -r /proc/$pid/status ]] || continue
    comm=$(<"/proc/$pid/comm")
    command=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
    case $command in
      *--type=renderer*) role=renderer ;;
      *--type=gpu-process*) role=gpu ;;
      *--type=utility*) role=utility ;;
      *' app-server '*) role=app-server ;;
      *) role=main-or-helper ;;
    esac
    pss=$(awk '/^Pss:/ {print $2; exit}' "/proc/$pid/smaps_rollup" 2>/dev/null || printf 0)
    rss=$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null || printf 0)
    printf '  pid=%s role=%s comm=%q pss_kib=%s rss_kib=%s\n' \
      "$pid" "$role" "$comm" "${pss:-0}" "${rss:-0}" >&2
  done
}

profile_failure() {
  printf 'profile-runtime: %s\n' "$*" >&2
  print_constrained_failure_diagnostics
  exit 1
}

constrained_tree_is_contained() {
  local root=$1 pid membership escaped=0
  (( memory_max_mib > 0 )) || return 0
  [[ -n $profile_scope_cgroup ]] || {
    printf 'profile-runtime: constrained scope cgroup was not resolved\n' >&2
    return 1
  }
  for pid in $(tree_pids "$root"); do
    membership=$(awk -F: '$1 == 0 {print $3}' "/proc/$pid/cgroup" 2>/dev/null || true)
    case $membership in
      "$profile_scope_cgroup"|"$profile_scope_cgroup"/*) ;;
      *)
        printf 'profile-runtime: pid %s escaped constrained cgroup %s into %s\n' \
          "$pid" "$profile_scope_cgroup" "${membership:-unknown}" >&2
        escaped=1
        ;;
    esac
  done
  (( escaped == 0 ))
}

resolve_constrained_measurement_scope() {
  local root=$1 membership unit expected_unit pid escaped
  (( memory_max_mib > 0 )) || return 0
  membership=$(awk -F: '$1 == 0 {print $3}' "/proc/$root/cgroup" 2>/dev/null || true)
  [[ -n $membership ]] || return 1
  if [[ $membership == "$profile_runner_scope_cgroup" || $membership == "$profile_runner_scope_cgroup"/* ]]; then
    return 0
  fi

  # Plasma 6 moves a mapped Wayland client into an app-id/PID scope, sometimes
  # leaving early children behind. Validate that exact destination, then move
  # the complete tree back into the already constrained runner scope. A single
  # common cgroup is required: two separately capped sibling scopes would not
  # enforce the 768 MiB whole-product budget.
  unit=${membership##*/}
  expected_unit="app-io.github.chatgpt_work_linux-$root.scope"
  [[ $unit == "$expected_unit" ]] || {
    printf 'profile-runtime: refusing unexpected constrained scope %s for pid %s\n' \
      "$membership" "$root" >&2
    return 1
  }
  [[ -w /sys/fs/cgroup$profile_runner_scope_cgroup/cgroup.procs ]] || return 1
  for _ in {1..5}; do
    for pid in $(tree_pids "$root"); do
      [[ -d /proc/$pid ]] || continue
      printf '%s\n' "$pid" >"/sys/fs/cgroup$profile_runner_scope_cgroup/cgroup.procs" || return 1
    done
    escaped=0
    for pid in $(tree_pids "$root"); do
      membership=$(awk -F: '$1 == 0 {print $3}' "/proc/$pid/cgroup" 2>/dev/null || true)
      [[ $membership == "$profile_runner_scope_cgroup" || $membership == "$profile_runner_scope_cgroup"/* ]] || escaped=1
    done
    (( escaped == 1 )) || return 0
    sleep 0.05
  done
  return 1
}

profile_tree_is_healthy() {
  local root=$1 pid command renderer=0 app_server=0
  kill -0 "$root" 2>/dev/null || return 1
  for pid in $(tree_pids "$root"); do
    [[ -r /proc/$pid/cmdline ]] || continue
    command=$(tr '\0' ' ' <"/proc/$pid/cmdline")
    [[ $command != *'--type=renderer'* ]] || renderer=1
    [[ $command != *' app-server '* ]] || app_server=1
  done
  (( renderer == 1 && app_server == 1 ))
}

stop_profile_processes() {
  local pids="" remaining=""
  local -a pid_list=()
  if [[ -n $profile_scope_unit ]]; then
    [[ $profile_runner_scope_unit != "$profile_scope_unit" ]] || profile_runner_scope_unit=
    systemctl --user stop "$profile_scope_unit" >/dev/null 2>&1 || true
    for _ in {1..30}; do
      systemctl --user is-active --quiet "$profile_scope_unit" 2>/dev/null || break
      sleep 0.1
    done
    profile_scope_unit=
    profile_scope_cgroup=
  fi
  if [[ -n $profile_runner_scope_unit ]]; then
    systemctl --user stop "$profile_runner_scope_unit" >/dev/null 2>&1 || true
    profile_runner_scope_unit=
  fi
  profile_runner_scope_cgroup=
  if [[ ${electron_pid:-} =~ ^[1-9][0-9]*$ ]]; then
    pids=$(tree_pids "$electron_pid" 2>/dev/null || true)
  fi
  pids=$(printf '%s\n%s\n%s\n' "$pids" "${launcher_pid:-}" "$(profile_related_pids)" |
    tr ' ' '\n' | awk '/^[1-9][0-9]*$/' | sort -un | tr '\n' ' ')
  read -r -a pid_list <<<"$pids"
  [[ ${#pid_list[@]} -eq 0 ]] || kill "${pid_list[@]}" 2>/dev/null || true
  for _ in {1..30}; do
    remaining=$(profile_related_pids | tr '\n' ' ')
    [[ -z $remaining ]] && break
    sleep 0.1
  done
  remaining=$(profile_related_pids | tr '\n' ' ')
  read -r -a pid_list <<<"$remaining"
  [[ ${#pid_list[@]} -eq 0 ]] || kill -KILL "${pid_list[@]}" 2>/dev/null || true
  launcher_pid=
  electron_pid=
}

cleanup() {
  stop_profile_processes
  [[ ! -e $temporary ]] || find "$temporary" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

launch_profile() {
  local -a launch_env=(
    env -u DISPLAY -u KDE_APPLICATIONS_AS_SCOPE
    CODEX_OZONE_PLATFORM=wayland
    CHATGPT_WORK_CODEX_HOME="$temporary/data/codex-home"
    XDG_SESSION_TYPE=wayland
    XDG_RUNTIME_DIR="$temporary/runtime"
    XDG_CONFIG_HOME="$temporary/config"
    XDG_DATA_HOME="$temporary/data"
    XDG_CACHE_HOME="$temporary/cache"
    XDG_STATE_HOME="$temporary/state"
  )
  local -a runner=("${launch_env[@]}" taskset -c "$cpu_set" "$launcher")
  profile_launch_sequence=$((profile_launch_sequence + 1))
  if (( memory_max_mib > 0 )); then
    profile_scope_unit="app-io.github.chatgpt_work_linux-profile-$$-$profile_launch_sequence.scope"
    profile_runner_scope_unit=$profile_scope_unit
    runner=(
      systemd-run --user --scope --quiet --collect
      # Use an app-style name, then verify containment: some desktops still
      # move mapped clients into a separate application scope.
      --unit="$profile_scope_unit"
      --property="MemoryHigh=${memory_high_mib}M"
      --property="MemoryMax=${memory_max_mib}M"
      --property=MemoryAccounting=yes
      --property=MemorySwapMax=0
      --property=CPUQuota=200%
      "${launch_env[@]}" taskset -c "$cpu_set" "$launcher"
    )
  fi
  "${runner[@]}" >"$temporary/launcher.out" 2>&1 &
  launcher_pid=$!
  profile_scope_cgroup=
  if (( memory_max_mib > 0 )); then
    for _ in {1..40}; do
      profile_scope_cgroup=$(systemctl --user show "$profile_scope_unit" \
        --property=ControlGroup --value 2>/dev/null || true)
      [[ -n $profile_scope_cgroup ]] && break
      sleep 0.05
    done
    [[ -n $profile_scope_cgroup && -w /sys/fs/cgroup$profile_scope_cgroup/memory.oom.group ]] || {
      printf 'profile-runtime: constrained scope does not expose writable group-OOM control\n' >&2
      return 1
    }
    profile_runner_scope_cgroup=$profile_scope_cgroup
    printf '1\n' >"/sys/fs/cgroup$profile_scope_cgroup/memory.oom.group"
  fi
}

start_ns=$(date +%s%N)
launch_profile

pid_file="$temporary/state/chatgpt-work-linux/app.pid"
peak_pss=0
ready=0
for sample_index in {1..180}; do
  electron_pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ $electron_pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$electron_pid" 2>/dev/null; then
    resolve_constrained_measurement_scope "$electron_pid" || {
      profile_failure 'could not constrain the actual Electron scope'
    }
    if (( sample_index % 4 == 0 )); then
      read -r current_pss _ _ < <(memory_kib "$electron_pid")
      (( current_pss > peak_pss )) && peak_pss=$current_pss
    fi
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
  profile_failure 'application did not become ready'
fi
ready_ns=$(date +%s%N)
constrained_tree_is_contained "$electron_pid" || {
  printf 'profile-runtime: refusing an invalid constrained-memory measurement\n' >&2
  exit 1
}
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
for sample_index in {1..180}; do
  electron_pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ $electron_pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$electron_pid" 2>/dev/null; then
    resolve_constrained_measurement_scope "$electron_pid" || {
      profile_failure 'could not constrain the actual Electron scope'
    }
    if (( sample_index % 4 == 0 )); then
      read -r current_pss _ _ < <(memory_kib "$electron_pid")
      (( current_pss > peak_pss )) && peak_pss=$current_pss
    fi
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
  profile_failure 'warm application launch did not become ready'
fi
ready_ns=$(date +%s%N)
constrained_tree_is_contained "$electron_pid" || {
  printf 'profile-runtime: refusing an invalid constrained-memory measurement\n' >&2
  exit 1
}
read -r warm_ready_pss _ _ < <(memory_kib "$electron_pid")
(( warm_ready_pss > peak_pss )) && peak_pss=$warm_ready_pss

# Measure process reuse while this second process tree remains active. An
# explicitly enabled warm-start socket takes the direct IPC path; fresh
# profiles use Electron's native second-instance handoff. Neither may leave a
# second renderer/app-server tree behind.
launch_socket="$temporary/runtime/chatgpt-work-linux/launch-action.sock"
for _ in {1..10}; do
  [[ -S $launch_socket ]] && break
  sleep 0.1
done
warm_handoff_start_ns=$(date +%s%N)
timeout 10 env -u DISPLAY -u KDE_APPLICATIONS_AS_SCOPE \
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
if [[ $(<"$pid_file") != "$electron_pid" ]] || ! kill -0 "$electron_pid" 2>/dev/null; then
  printf 'profile-runtime: warm handoff replaced the active Electron process\n' >&2
  exit 1
fi
if [[ -S $launch_socket ]]; then
  handoff_mode=warm-start-ipc
  rg -q 'Sent launch args over warm-start IPC' "$log_file" || {
    printf 'profile-runtime: enabled warm handoff did not use IPC\n' >&2
    exit 1
  }
else
  handoff_mode=electron-second-instance
  rg -q 'using Electron second-instance handoff' "$log_file" || {
    printf 'profile-runtime: default process reuse did not use Electron handoff\n' >&2
    exit 1
  }
fi

# Allow authentication, catalog sync, and first-render work to quiesce before
# measuring idle CPU and settled memory.
settle_samples=$settle_seconds
for ((sample = 0; sample < settle_samples; sample++)); do
  kill -0 "$electron_pid" 2>/dev/null || {
    profile_failure 'Electron exited while settling'
  }
  read -r current_pss _ _ < <(memory_kib "$electron_pid")
  (( current_pss > peak_pss )) && peak_pss=$current_pss
  sleep 1
done
read -r settled_pss settled_rss process_count < <(memory_kib "$electron_pid")
(( settled_pss > peak_pss )) && peak_pss=$settled_pss
profile_tree_is_healthy "$electron_pid" || {
  printf 'profile-runtime: required renderer or app-server is not healthy after settling\n' >&2
  exit 1
}

declare -A cpu_ticks_before=()
while read -r identity ticks; do
  [[ -n $identity ]] && cpu_ticks_before[$identity]=$ticks
done < <(cpu_snapshot "$electron_pid")
declare -A process_ticks_before=()
if [[ ${CHATGPT_WORK_PROFILE_PROCESS_DETAILS:-0} == 1 ]]; then
  for pid in $(tree_pids "$electron_pid"); do
    [[ -r /proc/$pid/stat ]] || continue
    process_ticks_before[$pid]=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || printf 0)
  done
fi
cpu_start_ns=$(date +%s%N)
cgroup_cpu_before=-1
if (( memory_max_mib > 0 )); then
  cgroup_cpu_before=$(awk '$1 == "usage_usec" {print $2}' \
    "/sys/fs/cgroup$profile_scope_cgroup/cpu.stat")
fi
sleep 4
ticks_before=0
ticks_after=0
while read -r identity ticks; do
  [[ -n $identity ]] || continue
  before=${cpu_ticks_before[$identity]:-$ticks}
  # Only compare the same PID incarnation. Processes which start during the
  # sample contribute from their first observation; exited processes cannot
  # make the aggregate negative.
  (( ticks >= before )) || before=$ticks
  ticks_before=$((ticks_before + before))
  ticks_after=$((ticks_after + ticks))
done < <(cpu_snapshot "$electron_pid")
cpu_end_ns=$(date +%s%N)
constrained_tree_is_contained "$electron_pid" || {
  printf 'profile-runtime: constrained process tree escaped after settling\n' >&2
  exit 1
}
cgroup_cpu_after=-1
memory_current_bytes=0
memory_peak_bytes=0
swap_current_bytes=0
swap_peak_bytes=0
oom_events=0
oom_kill_events=0
memory_pressure_avg10=0
if (( memory_max_mib > 0 )); then
  cgroup_root="/sys/fs/cgroup$profile_scope_cgroup"
  cgroup_cpu_after=$(awk '$1 == "usage_usec" {print $2}' "$cgroup_root/cpu.stat")
  memory_current_bytes=$(<"$cgroup_root/memory.current")
  memory_peak_bytes=$(<"$cgroup_root/memory.peak")
  swap_current_bytes=$(<"$cgroup_root/memory.swap.current")
  [[ ! -r $cgroup_root/memory.swap.peak ]] || swap_peak_bytes=$(<"$cgroup_root/memory.swap.peak")
  oom_events=$(awk '$1 == "oom" {print $2}' "$cgroup_root/memory.events")
  oom_kill_events=$(awk '$1 == "oom_kill" {print $2}' "$cgroup_root/memory.events")
  memory_pressure_avg10=$(awk '$1 == "some" {for (i=2;i<=NF;i++) if ($i ~ /^avg10=/) {sub(/^avg10=/,"",$i); print $i}}' \
    "$cgroup_root/memory.pressure")
  (( oom_events == 0 && oom_kill_events == 0 )) || {
    printf 'profile-runtime: constrained run encountered OOM events (oom=%s oom_kill=%s)\n' \
      "$oom_events" "$oom_kill_events" >&2
    print_constrained_failure_diagnostics
    exit 1
  }
fi
profile_tree_is_healthy "$electron_pid" || {
  printf 'profile-runtime: required renderer or app-server exited during CPU sampling\n' >&2
  exit 1
}
clock_ticks=$(getconf CLK_TCK)
runtime_root=$(dirname -- "$(readlink -f -- "$launcher")")
generated_size_bytes=$(du -sb -- "$runtime_root" | awk '{print $1}')

python3 - "$cold_start_ns" "$cold_ready_ns" "$cold_peak_pss" \
  "$start_ns" "$ready_ns" "$settled_pss" "$settled_rss" "$peak_pss" \
  "$process_count" "$ticks_before" "$ticks_after" "$cpu_start_ns" "$cpu_end_ns" \
  "$clock_ticks" "$cpu_set" "$warm_handoff_start_ns" "$warm_handoff_end_ns" "$handoff_mode" \
  "$generated_size_bytes" "$memory_high_mib" "$memory_max_mib" \
  "$cgroup_cpu_before" "$cgroup_cpu_after" "$memory_current_bytes" "$memory_peak_bytes" \
  "$swap_current_bytes" "$swap_peak_bytes" "$oom_events" "$oom_kill_events" \
  "$memory_pressure_avg10" <<'PY'
import sys
(cold_start, cold_ready, cold_peak, start, ready, pss, rss, peak, processes,
 ticks0, ticks1, cpu0, cpu1, hz, cpus, handoff_start, handoff_end, handoff_mode,
 generated_size, memory_high, memory_max, cgroup_cpu0, cgroup_cpu1,
 memory_current, memory_peak, swap_current, swap_peak, oom, oom_kill,
 pressure_avg10) = sys.argv[1:]
cold_launch = (int(cold_ready) - int(cold_start)) / 1e9
warm_launch = (int(ready) - int(start)) / 1e9
warm_handoff = (int(handoff_end) - int(handoff_start)) / 1e9
wall = (int(cpu1) - int(cpu0)) / 1e9
cpu = ((int(ticks1) - int(ticks0)) / int(hz)) / wall * 100 if wall else 0
if int(cgroup_cpu0) >= 0 and int(cgroup_cpu1) >= int(cgroup_cpu0) and wall:
    cpu = ((int(cgroup_cpu1) - int(cgroup_cpu0)) / 1e6) / wall * 100
print(f"cold_launch_to_ready_seconds={cold_launch:.3f}")
print(f"warm_launch_to_ready_seconds={warm_launch:.3f}")
print(f"warm_handoff_seconds={warm_handoff:.3f}")
print(f"handoff_mode={handoff_mode}")
print(f"cpu_set={cpus}")
print(f"process_count={processes}")
print(f"settled_pss_mib={int(pss) / 1024:.1f}")
print(f"settled_rss_mib={int(rss) / 1024:.1f}")
print(f"cold_sampled_peak_pss_mib={int(cold_peak) / 1024:.1f}")
print(f"sampled_peak_pss_mib={int(peak) / 1024:.1f}")
print(f"settled_cpu_percent={cpu:.2f}")
print(f"generated_size_mib={int(generated_size) / 1024 / 1024:.1f}")
print(f"memory_high_mib={memory_high}")
print(f"memory_max_mib={memory_max}")
print(f"cgroup_memory_current_mib={int(memory_current) / 1024 / 1024:.1f}")
print(f"cgroup_memory_peak_mib={int(memory_peak) / 1024 / 1024:.1f}")
print(f"cgroup_swap_current_mib={int(swap_current) / 1024 / 1024:.1f}")
print(f"cgroup_swap_peak_mib={int(swap_peak) / 1024 / 1024:.1f}")
print(f"cgroup_oom_events={oom}")
print(f"cgroup_oom_kill_events={oom_kill}")
print(f"memory_pressure_some_avg10={pressure_avg10}")
if int(memory_max) > 0:
    failures = []
    if cold_launch > 20: failures.append(f"cold launch {cold_launch:.3f}s > 20s")
    if warm_launch > 15: failures.append(f"warm launch {warm_launch:.3f}s > 15s")
    if int(processes) > 10: failures.append(f"process count {processes} > 10")
    if cpu > 10: failures.append(f"settled CPU {cpu:.2f}% > 10%")
    if int(generated_size) > 800 * 1024 * 1024:
        failures.append("generated size > 800 MiB")
    if failures:
        raise SystemExit("profile-runtime: constrained budgets failed: " + "; ".join(failures))
    print("constrained_budget_status=passed")
PY

if [[ ${CHATGPT_WORK_PROFILE_PROCESS_DETAILS:-0} == 1 ]]; then
  printf 'processes (CPU is sampled; PSS accounts shared pages proportionally):\n'
  for pid in $(tree_pids "$electron_pid"); do
    [[ -r /proc/$pid/status ]] || continue
    rss=$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status")
    pss=$(awk '/^Pss:/ {print $2; exit}' "/proc/$pid/smaps_rollup" 2>/dev/null || printf 0)
    ticks=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || printf 0)
    before=${process_ticks_before[$pid]:-$ticks}
    (( ticks >= before )) || before=$ticks
    cpu=$(awk -v delta="$((ticks - before))" -v hz="$clock_ticks" \
      -v wall_ns="$((cpu_end_ns - cpu_start_ns))" \
      'BEGIN { if (wall_ns > 0) printf "%.2f", (delta / hz) / (wall_ns / 1000000000) * 100; else print "0.00" }')
    printf '%8s %7s%% %10s KiB PSS %10s KiB RSS %s\n' \
      "$pid" "$cpu" "${pss:-0}" "${rss:-0}" "$(tr '\0' ' ' <"/proc/$pid/cmdline")"
  done
fi
