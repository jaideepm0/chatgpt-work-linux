#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_dir="$(cd -- "$script_dir/.." && pwd -P)"
cache_dir="${CHATGPT_WORK_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux/upstream}"
artifact="${CHATGPT_WORK_CANDIDATE_DMG_PATH:-$cache_dir/candidates/ChatGPT.candidate.dmg}"
snapshot="${CHATGPT_WORK_UPSTREAM_SNAPSHOT:-$repo_dir/docs/upstream-snapshot.json}"
candidate="${CHATGPT_WORK_CANDIDATE_SNAPSHOT:-$cache_dir/candidates/upstream-snapshot.candidate.json}"
headers="${CHATGPT_WORK_CANDIDATE_HEADERS:-$cache_dir/candidates/response.headers}"
validation_receipt="${CHATGPT_WORK_CANDIDATE_VALIDATION_RECEIPT:-$cache_dir/candidates/validation.json}"
official_url=https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg
offline=0
check_only=0
promote=0
allow_downgrade=0
expected_version=
expected_sha256=

usage() {
    cat <<'EOF'
Usage: scripts/refresh-upstream-snapshot.sh [OPTIONS]

Download and inspect a candidate from the official unified ChatGPT DMG URL.
Candidate bytes and metadata remain isolated from the reviewed build cache.

Options:
  --artifact PATH          private candidate DMG path
  --snapshot PATH          reviewed metadata JSON to compare/update
  --offline                inspect the existing candidate without network access
  --check                  fail when a candidate differs; never promote it
  --promote                explicitly promote an already downloaded candidate
  --expected-version VER   exact reviewed version required with --promote
  --expected-sha256 SHA    exact reviewed digest required with --promote
  --validation-receipt P  successful isolated validation receipt
  --allow-downgrade        permit an explicitly reviewed version downgrade
  -h, --help               show this help

Run once without --promote, review the candidate DMG/snapshot and adapter drift,
then run --promote with both exact expected values. Promotion is offline and
publishes a content-addressed artifact before atomically switching the snapshot.
EOF
}

die() {
    printf 'refresh-upstream-snapshot: %s\n' "$*" >&2
    exit 1
}

need_value() {
    [[ $# -ge 2 && -n $2 ]] || die "$1 requires a value"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --artifact) need_value "$@"; artifact=$2; shift 2 ;;
        --snapshot) need_value "$@"; snapshot=$2; shift 2 ;;
        --offline) offline=1; shift ;;
        --check) check_only=1; shift ;;
        --promote) promote=1; shift ;;
        --expected-version) need_value "$@"; expected_version=$2; shift 2 ;;
        --expected-sha256) need_value "$@"; expected_sha256=${2,,}; shift 2 ;;
        --validation-receipt) need_value "$@"; validation_receipt=$2; shift 2 ;;
        --allow-downgrade) allow_downgrade=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ $snapshot == /* && $snapshot != / ]] || die 'snapshot path must be absolute and non-root'
[[ $artifact == /* && $artifact != / ]] || die 'candidate artifact path must be absolute and non-root'
if [[ $promote -eq 1 ]]; then
    [[ -n $expected_version ]] || die '--promote requires --expected-version'
    [[ $expected_sha256 =~ ^[0-9a-f]{64}$ ]] || die '--promote requires a lowercase 64-character --expected-sha256'
    offline=1
fi
if [[ $check_only -eq 1 && $promote -eq 1 ]]; then
    die '--check and --promote are mutually exclusive'
fi

mkdir -p -- "$cache_dir/candidates" "$cache_dir/artifacts" "$(dirname -- "$snapshot")" "$repo_dir/.work"
chmod 0700 "$cache_dir" "$cache_dir/candidates" "$cache_dir/artifacts"
if [[ ${CHATGPT_WORK_UPSTREAM_LOCK_HELD:-0} != 1 ]]; then
    exec {upstream_lock_fd}>"$repo_dir/.work/upstream-transaction.lock"
    flock "$upstream_lock_fd"
    export CHATGPT_WORK_UPSTREAM_LOCK_HELD=1
fi

fetch_args=(
    --output "$artifact"
    --metadata "$candidate"
    --headers "$headers"
    --allow-unreviewed
)
[[ $offline -eq 0 ]] || fetch_args+=(--offline)
"$script_dir/fetch-upstream.sh" "${fetch_args[@]}"

normalized="$candidate.normalized.$$"
artifact_part=
publish=
cleanup() {
    rm -f -- "$normalized" ${artifact_part:+"$artifact_part"} ${publish:+"$publish"}
}
trap cleanup EXIT HUP INT TERM

python3 - "$candidate" "$normalized" "$official_url" <<'PY'
import json
import re
import sys

source_path, output_path, official_url = sys.argv[1:]
with open(source_path, encoding="utf-8") as handle:
    value = json.load(handle)
if value.get("schema_version") != 3:
    raise SystemExit("candidate does not use upstream snapshot schema 3")
if value.get("source", {}).get("url") != official_url:
    raise SystemExit("candidate is not tied to the exact official URL")
verification = value.get("verification", {})
if verification.get("archive_test") != "passed" or verification.get("artifact_executed") is not False:
    raise SystemExit("candidate lacks archive-integrity/non-execution attestations")
artifact = value.get("artifact", {})
if artifact.get("archive_format") != "dmg":
    raise SystemExit("candidate is not an Apple DMG")
digest = artifact.get("sha256")
if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
    raise SystemExit("candidate has an invalid SHA-256")
application = value.get("application", {})
if application.get("implementation") != "electron":
    raise SystemExit("official candidate is not the unified Electron application")
if application.get("bundle_identifier") != "com.openai.codex":
    raise SystemExit("official candidate has an unexpected bundle identifier")
version = application.get("short_version")
if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", version):
    raise SystemExit("candidate has an invalid application version")
if "app.asar" not in application.get("electron_markers", []):
    raise SystemExit("candidate lacks the packaged Electron renderer")
required_plugins = {"browser", "chrome", "computer-use"}
missing = sorted(required_plugins - set(application.get("bundled_plugins", [])))
if missing:
    raise SystemExit("candidate lacks required unified plugins: " + ", ".join(missing))
artifact["name"] = "ChatGPT.dmg"
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
mv -f -- "$normalized" "$candidate"
candidate_metadata_sha=$(sha256sum "$candidate" | awk '{print $1}')

snapshot_current=0
if [[ -f $snapshot ]] && cmp -s -- "$candidate" "$snapshot"; then
    snapshot_current=1
    printf 'Upstream snapshot is current: %s\n' "$snapshot"
    [[ $promote -eq 1 ]] || exit 0
fi

if [[ $snapshot_current -eq 0 ]]; then
python3 - "$snapshot" "$candidate" <<'PY'
import json
import os
import sys

old_path, new_path = sys.argv[1:]
old = {}
if os.path.isfile(old_path):
    with open(old_path, encoding="utf-8") as handle:
        old = json.load(handle)
with open(new_path, encoding="utf-8") as handle:
    new = json.load(handle)

def identity(value):
    app = value.get("application", {})
    artifact = value.get("artifact", {})
    return app.get("short_version", "missing"), app.get("bundle_version", "missing"), artifact.get("sha256", "missing")

print("Upstream candidate drift:")
print("  reviewed:  version=%s build=%s sha256=%s" % identity(old))
print("  candidate: version=%s build=%s sha256=%s" % identity(new))
old_plugins = set(old.get("application", {}).get("bundled_plugins", []))
new_plugins = set(new.get("application", {}).get("bundled_plugins", []))
print("  bundled plugins: +%d -%d" % (len(new_plugins - old_plugins), len(old_plugins - new_plugins)))
PY
fi

if [[ $check_only -eq 1 ]]; then
    die 'reviewed snapshot differs from the candidate'
fi
if [[ $promote -eq 0 ]]; then
    printf 'Candidate retained for review; the reviewed snapshot and artifact cache were not changed.\n'
    printf 'Candidate DMG: %s\nCandidate snapshot: %s\n' "$artifact" "$candidate"
    exit 0
fi

readarray -t identities < <(python3 - "$snapshot" "$candidate" <<'PY'
import json
import os
import sys

old_path, candidate_path = sys.argv[1:]
old_version = ""
if os.path.isfile(old_path):
    with open(old_path, encoding="utf-8") as handle:
        old_version = json.load(handle).get("application", {}).get("short_version", "")
with open(candidate_path, encoding="utf-8") as handle:
    candidate = json.load(handle)
print(old_version)
print(candidate["application"]["short_version"])
print(candidate["artifact"]["sha256"])
print(candidate["artifact"]["size"])
PY
)
old_version=${identities[0]}
candidate_version=${identities[1]}
candidate_sha256=${identities[2]}
candidate_size=${identities[3]}
[[ $candidate_version == "$expected_version" ]] || die "candidate version $candidate_version does not match explicit approval $expected_version"
[[ $candidate_sha256 == "$expected_sha256" ]] || die "candidate SHA-256 $candidate_sha256 does not match explicit approval $expected_sha256"

python3 - "$validation_receipt" "$candidate_version" "$candidate_sha256" "$candidate_metadata_sha" <<'PY'
import json
import sys

path, version, digest, snapshot_digest = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        receipt = json.load(handle)
except OSError as error:
    raise SystemExit(f"candidate lacks a successful isolated validation receipt: {error}")
if receipt.get("schemaVersion") != 1 or receipt.get("status") != "passed":
    raise SystemExit("candidate validation receipt is not successful")
expected = {
    "version": version,
    "sha256": digest,
    "snapshotSha256": snapshot_digest,
}
for key, value in expected.items():
    if receipt.get(key) != value:
        raise SystemExit(f"candidate validation receipt has the wrong {key}")
required = {
    "build",
    "doctor",
    "smoke-wayland",
    "profile-runtime",
    "profile-runtime-constrained",
}
missing = sorted(required - set(receipt.get("validations", [])))
if missing:
    raise SystemExit("candidate validation receipt lacks: " + ", ".join(missing))
PY

if [[ -n $old_version && $allow_downgrade -eq 0 ]]; then
    python3 - "$old_version" "$candidate_version" <<'PY'
import sys

def version(value):
    return tuple(int(part) for part in value.split("."))

old, new = sys.argv[1:]
if version(new) < version(old):
    raise SystemExit(f"refusing version downgrade {old} -> {new}; use --allow-downgrade after explicit review")
PY
fi

artifact_dir="$cache_dir/artifacts/$candidate_sha256"
final_artifact="$artifact_dir/ChatGPT.dmg"
artifact_part="$artifact_dir/.ChatGPT.dmg-new-$$"
mkdir -p -- "$artifact_dir"
chmod 0700 "$artifact_dir"
if [[ -e $final_artifact ]]; then
    existing_sha=$(sha256sum "$final_artifact" | awk '{print $1}')
    existing_size=$(stat -c %s -- "$final_artifact")
    [[ $existing_sha == "$candidate_sha256" && $existing_size == "$candidate_size" ]] || \
        die "existing immutable artifact failed verification: $final_artifact"
else
    cp -a --reflink=auto -- "$artifact" "$artifact_part"
    copied_sha=$(sha256sum "$artifact_part" | awk '{print $1}')
    copied_size=$(stat -c %s -- "$artifact_part")
    [[ $copied_sha == "$candidate_sha256" && $copied_size == "$candidate_size" ]] || \
        die 'candidate changed while publishing the immutable artifact'
    chmod 0400 "$artifact_part"
    mv -- "$artifact_part" "$final_artifact"
fi
[[ $(sha256sum "$candidate" | awk '{print $1}') == "$candidate_metadata_sha" ]] || \
    die 'candidate metadata changed during promotion'
install -m 0400 -- "$candidate" "$artifact_dir/upstream-snapshot.json"
[[ ! -f $headers ]] || install -m 0400 -- "$headers" "$artifact_dir/response.headers"

python3 - "$artifact_dir/promotion.json" "$old_version" "$candidate_version" \
    "$candidate_sha256" "$candidate_metadata_sha" <<'PY'
from datetime import datetime, timezone
import json
import os
import sys

path, previous, version, digest, metadata_digest = sys.argv[1:]
value = {
    "schemaVersion": 1,
    "promotedAt": datetime.now(timezone.utc).isoformat(),
    "previousVersion": previous or None,
    "version": version,
    "sha256": digest,
    "snapshotSha256": metadata_digest,
    "approval": "explicit-version-and-sha256",
}
temporary = path + f".new-{os.getpid()}"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.chmod(temporary, 0o400)
os.replace(temporary, path)
PY
publish="$(mktemp --tmpdir="$(dirname -- "$snapshot")" .upstream-snapshot.XXXXXX)"
install -m 0644 -- "$candidate" "$publish"
mv -f -- "$publish" "$snapshot"
trap - EXIT HUP INT TERM
cleanup
printf 'Promoted reviewed upstream %s (%s).\n' "$candidate_version" "$candidate_sha256"
printf 'Immutable artifact: %s\nReviewed snapshot: %s\n' "$final_artifact" "$snapshot"
