#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cache_dir="${CHATGPT_WORK_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux/upstream}"
candidate_dmg="${CHATGPT_WORK_CANDIDATE_DMG_PATH:-$cache_dir/candidates/ChatGPT.candidate.dmg}"
candidate_snapshot="${CHATGPT_WORK_CANDIDATE_SNAPSHOT:-$cache_dir/candidates/upstream-snapshot.candidate.json}"
receipt="${CHATGPT_WORK_CANDIDATE_VALIDATION_RECEIPT:-$cache_dir/candidates/validation.json}"
release_gates=1
allow_memory_pressure=${CHATGPT_WORK_PROFILE_ALLOW_MEMORY_PRESSURE:-0}

while [[ $# -gt 0 ]]; do
  case $1 in
    --release-gates) release_gates=1 ;;
    --skip-release-gates) release_gates=0 ;;
    --allow-memory-pressure) allow_memory_pressure=1 ;;
    -h|--help)
      printf '%s\n' \
        'Usage: scripts/validate-upstream-candidate.sh [--release-gates|--skip-release-gates] [--allow-memory-pressure]'
      exit 0 ;;
    *) printf 'validate-upstream-candidate: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[[ $allow_memory_pressure == 0 || $allow_memory_pressure == 1 ]] || {
  printf 'validate-upstream-candidate: memory-pressure consent must be 0 or 1\n' >&2
  exit 2
}
if [[ $release_gates -eq 1 && $allow_memory_pressure -ne 1 ]]; then
  printf '%s\n' \
    'validate-upstream-candidate: release gates include a kernel OOM stress test.' \
    'Re-run with --allow-memory-pressure only after saving other desktop work.' >&2
  exit 2
fi

[[ -f $candidate_dmg && -f $candidate_snapshot ]] || {
  printf 'validate-upstream-candidate: acquire a candidate with make refresh-upstream first\n' >&2
  exit 1
}
mkdir -p -- "$repo_root/.work" "$(dirname -- "$receipt")"
exec {upstream_lock_fd}>"$repo_root/.work/upstream-transaction.lock"
flock "$upstream_lock_fd"
export CHATGPT_WORK_UPSTREAM_LOCK_HELD=1
rm -f -- "$receipt"

readarray -t identity < <(python3 - "$candidate_snapshot" "$candidate_dmg" <<'PY'
import hashlib
import json
import os
import sys

snapshot_path, dmg_path = sys.argv[1:]
raw = open(snapshot_path, "rb").read()
value = json.loads(raw)
expected = value["artifact"]
digest = hashlib.sha256()
with open(dmg_path, "rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
actual = digest.hexdigest()
if actual != expected["sha256"] or os.path.getsize(dmg_path) != int(expected["size"]):
    raise SystemExit("candidate DMG differs from candidate snapshot")
print(value["application"]["short_version"])
print(actual)
print(hashlib.sha256(raw).hexdigest())
PY
)
version=${identity[0]}
digest=${identity[1]}
snapshot_digest=${identity[2]}
output="$repo_root/.work/candidate-validation-$digest"
reports="$repo_root/.work/reports/candidate-validation-$version"

env CHATGPT_WORK_UPSTREAM_LOCK_HELD=1 \
  CHATGPT_WORK_UPSTREAM_SNAPSHOT="$candidate_snapshot" \
  CHATGPT_WORK_DMG_PATH="$candidate_dmg" \
  CHATGPT_WORK_BUILD_DIR="$output" \
  CHATGPT_WORK_REPORT_DIR="$reports" \
  make -C "$repo_root" build
python3 "$repo_root/scripts/verify-reviewed-build.py" "$output" "$candidate_snapshot"
"$output/start.sh" doctor --json >/dev/null
bash "$repo_root/scripts/smoke-wayland.sh" "$output/start.sh"
validations=(build doctor smoke-wayland)
if [[ $release_gates -eq 1 ]]; then
  bash "$repo_root/scripts/profile-runtime.sh" "$output/start.sh"
  CHATGPT_WORK_PROFILE_SEED_CODEX_HOME=/nonexistent \
    CHATGPT_WORK_PROFILE_SEED_STATE=/nonexistent \
    CHATGPT_WORK_PROFILE_SEED_CONFIG=/nonexistent \
    CHATGPT_WORK_PROFILE_ALLOW_MEMORY_PRESSURE=1 \
    CHATGPT_WORK_PROFILE_MEMORY_HIGH_MIB=704 \
    CHATGPT_WORK_PROFILE_MEMORY_MAX_MIB=768 \
    bash "$repo_root/scripts/profile-runtime.sh" "$output/start.sh"
  validations+=(profile-runtime profile-runtime-constrained)
fi
adapter_commit=$(<"$output/.codex-linux/adapter-commit")
manifest_sha=$(sha256sum "$output/.codex-linux/SHA256SUMS" | awk '{print $1}')
validations_csv=$(IFS=,; printf '%s' "${validations[*]}")
receipt_part="$receipt.new-$$"
python3 - "$receipt_part" "$version" "$digest" "$snapshot_digest" \
  "$adapter_commit" "$manifest_sha" "$validations_csv" <<'PY'
from datetime import datetime, timezone
import json
import os
import sys

path, version, digest, snapshot_digest, adapter, manifest, validations = sys.argv[1:]
value = {
    "schemaVersion": 1,
    "status": "passed",
    "validatedAt": datetime.now(timezone.utc).isoformat(),
    "version": version,
    "sha256": digest,
    "snapshotSha256": snapshot_digest,
    "adapterCommit": adapter,
    "buildManifestSha256": manifest,
    "validations": validations.split(","),
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.chmod(path, 0o400)
PY
mv -f -- "$receipt_part" "$receipt"
printf 'Candidate validation passed: %s\n' "$receipt"
