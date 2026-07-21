# Performance and resource architecture

Date: 2026-07-18

## Outcome

The exact unified ChatGPT desktop renderer remains the production fidelity
boundary. It is not currently a sub-768-MiB application: the reviewed build
settled at 1,151.0 MiB PSS across nine processes in the latest two-core sample.
The compatibility layer can remove persistence, duplicate payloads, cache
rewrites, and packaging waste, but it must not claim that those changes erase
the upstream renderer's memory floor.

The production architecture is therefore an on-demand full-product plane, not
a resident desktop service. Closing the final window must release the complete
tree unless the user explicitly opts into tray or warm-start behavior.

## Evidence

The current reviewed generated build (`26.715.21425`) produced this 20-second
settled sample with canonical signed-in state copied into an isolated profile:

| Component | PSS MiB | Role |
| --- | ---: | --- |
| Packaged renderer | 466.0 | Unified Chat/Work/Codex UI |
| Electron main | 326.1 | Windows, IPC, application lifecycle |
| Codex native app-server | 146.0 | Local task/session service |
| GPU process | 101.3 | Wayland/Chromium compositing |
| Node CLI wrapper | 51.1 | App-server launch wrapper |
| Network utility + zygotes | 60.5 | Chromium process infrastructure |
| **Total** | **1,151.0** | Nine processes; 2.46% settled CPU |

PSS is the correct Linux aggregate here because it proportionally distributes
shared mappings rather than counting every shared page once per process; this
matches the kernel's `/proc` definition. The profiler now reports PSS and RSS
per process, samples startup peaks, and records generated size.

The 768 MiB cgroup lane also has a desktop-integration hazard. Plasma can move
the mapped Wayland application from the transient profiling scope into a sibling
`app-io.github.chatgpt_work_linux-*.scope`. Memory charges do not move with a
process after cgroup migration, so adding two separately capped scopes would not
reconstruct a valid constrained run. The profiler now validates the exact
Plasma-created scope, moves the complete process tree back into the original
runner scope, and rechecks containment. The latest candidate remained contained
but was genuinely OOM-killed at the 768 MiB peak, so the gate still fails.

## Architecture

1. **Immutable acquisition transaction.** Accept only the reviewed URL, size,
   hash, version, and structure. Inspect an update in a candidate path before
   replacing the private cache. Build from an exact adapter commit and publish
   only after all semantic and native checks pass.
2. **Thin deterministic launcher.** Do synchronous work only when it can alter
   launch correctness. Repair a missing CLI synchronously, but keep registry
   checks and upgrades in explicit update transactions. Record plugin content
   integrity at build time, publish caches atomically, and reuse an exact-build
   read-only cache without hashing payloads on every cold launch.
3. **One on-demand product plane.** Use one packaged `app://` renderer, normal
   Chromium background throttling, GPU compositing, sandboxing, and Electron's
   native single-instance handoff. Keep Quick Chat prewarming, tray residency,
   and the private warm socket disabled by default.
4. **Capability processes on demand.** Computer Use, browser automation, read
   aloud, and other helpers are packaged capabilities, not startup daemons.
   Their binaries and cache metadata may exist on disk without a live process.
5. **Two measurement lanes.** The representative diagnostic lane may seed the
   user's signed-in state and records cold/warm readiness, per-process
   PSS/RSS/CPU, process count, and size on two CPUs. The sterile release lane
   uses no ambient profile, plugin, history, or settings state and
   must additionally apply cgroup `memory.high`/`memory.max`, verify every PID
   remains below that cgroup, record `memory.events`/peak and PSI, and treat OOM
   or cgroup escape as failure. The latest candidate produced a valid contained
   measurement but hit the exact 768 MiB maximum, so it has no release receipt.

The constrained lane requires explicit per-invocation consent because an
expected release failure still exercises the kernel OOM killer and desktop
environments may surface that isolated event as a system-low-memory warning.
Before creating the cgroup, the profiler requires host-available memory greater
than the configured limit by at least 1 GiB. On failure it records only bounded
cgroup counters and sanitized process roles/memory totals; it does not dump
command arguments, profile contents, or authentication state.

This follows Electron's own guidance to measure first, avoid loading and work
too early, keep main-process I/O asynchronous, and pause expensive work for
hidden windows. Electron documents that each window has a renderer, that a
destroyed window terminates its renderer, and that `ready-to-show` causes an
initially hidden renderer to paint as visible. It also exposes
`app.getAppMetrics()` for application-local diagnostics; Linux PSS remains the
external release metric.

## Optimization order

Changes should be accepted in this order so measurements stay attributable:

1. Correct lifecycle persistence and eliminate duplicate renderer trees.
2. Remove repeated launcher cache writes and unnecessary synchronous probes.
3. Remove only proven packaging files and symbols, with executable self-checks
   after transformation. Preserve the adjacent managed Node/npm toolchain used
   for automatic Codex CLI installation and repair.
4. Attribute upstream main/renderer/app-server memory using internal metrics,
   heap snapshots, and Chromium tracing on the exact reviewed build.
5. Change upstream behavior only through exact, reviewed, drift-detecting
   transformations; prefer documented preferences and upstream fixes.

Unsafe heap caps, sandbox bypasses, software rendering, public-web fallbacks,
and deleting product features are not performance optimizations. A lightweight
native controller would be valid only as an explicit launcher/doctor that
consumes no resources after starting the product; it must never substitute a
different UI for the unified application plane.

## Primary references

- [Electron process model](https://www.electronjs.org/docs/latest/tutorial/process-model)
- [Electron performance guidance](https://www.electronjs.org/docs/latest/tutorial/performance)
- [Electron BrowserWindow visibility and throttling](https://www.electronjs.org/docs/latest/api/browser-window)
- [Electron application process metrics](https://www.electronjs.org/docs/latest/api/app#appgetappmetrics)
- [Linux cgroup v2 resource and migration semantics](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- [Linux pressure stall information](https://www.kernel.org/doc/html/latest/accounting/psi.html)
- [Linux `/proc` PSS definition](https://www.kernel.org/doc/html/latest/filesystems/proc.html)
- [systemd resource controls](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html)
- [Cargo release profile and stripping controls](https://doc.rust-lang.org/cargo/reference/profiles.html)
