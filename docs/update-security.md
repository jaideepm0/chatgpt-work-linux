# Update security and release workflow

## Security model

The official URL is mutable, so its current response is discovery input—not a
trust root. TLS, exact host allowlisting, content type, size bounds, archive
integrity, and structural inspection protect transport and parsing, but a new
digest becomes trusted only through explicit review and promotion.

Normal builds accept exactly the version, size, SHA-256, application identity,
and source URL in `docs/upstream-snapshot.json`. A matching cached DMG remains
usable after the mutable URL advances. macOS binaries are inspected but never
executed, and macOS code-signature verification is not claimed on Linux.

## Transaction phases

1. `make check-update` performs a metadata-only HEAD request. Successful checks
   persist a six-hour minimum plus randomized jitter; failures use persisted
   bounded exponential backoff. There is no synchronized polling daemon.
2. `make refresh-upstream` downloads into `upstream/candidates`. It never edits
   the reviewed snapshot or content-addressed cache.
3. Review the candidate snapshot, hash, version, application identity, plugin
   inventory, adapter drift, and upstream provenance outside the promotion
   command.
4. After saving other desktop work, run
   `CHATGPT_WORK_PROFILE_ALLOW_MEMORY_PRESSURE=1 make validate-upstream-candidate`.
   It creates a promotable receipt only after an isolated exact build, manifest
   verification, doctor, Wayland smoke, and both performance lanes. The explicit
   consent is required because a failing 768 MiB cgroup gate invokes the kernel
   OOM killer and may generate a desktop notification. The profiler first
   requires at least the limit plus 1 GiB of host-available memory and emits
   bounded cgroup diagnostics on failure. `--skip-release-gates` is diagnostic
   only; its incomplete receipt cannot authorize promotion.
5. Promote offline with both `--expected-version` and `--expected-sha256`.
   Downgrades additionally require `--allow-downgrade`. Promotion stores the DMG
   under `upstream/artifacts/<sha256>/`, requires the matching validation receipt,
   records a local approval receipt, and atomically replaces only the metadata
   snapshot after immutable bytes exist.
6. Commit and review the snapshot change. `make update-user` then runs repository
   checks, an exact build, doctor, Wayland smoke validation, immutable user
   installation, installed doctor, and Computer Use doctor. Release candidates
   use `scripts/update-user.sh --release-gates --allow-memory-pressure` to add
   both performance lanes.
7. `make rollback-user` verifies both installed manifests and doctors before
   atomically exchanging `current` and `previous`.

The upstream transaction, build, install, uninstall, and rollback paths use
advisory locks. Direct concurrent installers serialize before verification,
link switching, and pruning.

The external Linux adapter is an exact Git commit whose deterministic archive
SHA-256 is source-controlled. Native Node sources are installed only through
that adapter commit's `package-lock.json` using `npm ci`, and the Linux Electron
runtime must match the reviewed per-version/per-architecture SHA-256 before
extraction. A new Electron or native-module version is therefore adapter review
work; it cannot silently resolve to newer registry or runtime bytes during a
build.

## Failure and recovery

- Failed discovery leaves reviewed bytes and metadata unchanged.
- Failed promotion may leave an orphan content-addressed artifact, which is
  harmless and can be inspected or pruned explicitly.
- Failed build leaves the active generated build and installed release intact.
- Failed install leaves `current` and `previous` unchanged.
- Interruption during rollback always leaves `current` pointing to a previously
  verified release; rerunning rollback repairs the secondary link if needed.
- The former singleton `ChatGPT.dmg` cache is migrated by verified reflink or
  copy only after exact review validation and is not deleted automatically.
  Noncanonical artifact names are never accepted as upstream input.
- Electron identity migration validates both cookie databases, excludes only
  regenerable caches, requires an idle profile, and retains a timestamped
  backup before any explicitly approved target replacement.

## Shipping checklist

Before shipping a reviewed version, run the commands in `AGENTS.md`, including
the two-core 768 MiB constrained lane. An OOM, cgroup escape, missing patch,
origin mismatch, sandbox bypass, unresolved dependency, failed installed
doctor, or failed Computer Use handshake blocks release. Do not reinterpret a
known failure as a pass.

The automated test suite additionally exercises candidate isolation, explicit
digest approval, offline reviewed reuse, downgrade rejection, failed-install
link preservation, lock blocking, repeated concurrent installation, manifest
verification, and rollback.
It also tests profile-copy integrity, cache exclusion, idempotence, refusal to
replace an unapproved target, and backup recovery.
