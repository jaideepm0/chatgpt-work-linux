#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_dir="$(cd -- "$script_dir/.." && pwd -P)"
artifact="$repo_dir/ChatGPT.dmg"
snapshot="$repo_dir/docs/upstream-snapshot.json"
cache_dir="${CHATGPT_WORK_CACHE_DIR:-$repo_dir/.cache/upstream}"
candidate="$cache_dir/upstream-snapshot.candidate.json"
headers="$cache_dir/response.headers"
offline=0
check_only=0

usage() {
    cat <<'EOF'
Usage: scripts/refresh-upstream-snapshot.sh [OPTIONS]

Refresh the checked-in, metadata-only snapshot of the official ChatGPT DMG.
The DMG stays gitignored and is never executed, patched, or packaged.

Options:
  --artifact PATH  ignored local DMG path (default: ./ChatGPT.dmg)
  --snapshot PATH  metadata JSON to check/update
  --offline        inspect the existing artifact without network access
  --check          fail when the checked-in snapshot differs; do not update it
  -h, --help       show this help
EOF
}

die() {
    printf 'refresh-upstream-snapshot: %s\n' "$*" >&2
    exit 1
}

need_value() {
    [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --artifact)
            need_value "$@"
            artifact="$2"
            shift 2
            ;;
        --snapshot)
            need_value "$@"
            snapshot="$2"
            shift 2
            ;;
        --offline)
            offline=1
            shift
            ;;
        --check)
            check_only=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

mkdir -p -- "$cache_dir" "$(dirname -- "$snapshot")"
fetch_args=(
    --output "$artifact"
    --metadata "$candidate"
    --headers "$headers"
)
if [ "$offline" -eq 1 ]; then
    fetch_args+=(--offline)
fi
"$script_dir/fetch-upstream.sh" "${fetch_args[@]}"

python3 - "$candidate" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    snapshot = json.load(handle)
if snapshot.get("schema_version") != 3:
    raise SystemExit("candidate does not use upstream snapshot schema 3")
if snapshot.get("verification", {}).get("artifact_executed") is not False:
    raise SystemExit("candidate does not attest non-execution")
application = snapshot.get("application", {})
if application.get("implementation") not in {"native-macos", "electron"}:
    raise SystemExit("official artifact has an unknown implementation")
if not (application.get("resource_bundles") or application.get("bundled_plugins") or application.get("electron_markers")):
    raise SystemExit("candidate has no structural application inventory")
PY

if [ -f "$snapshot" ] && cmp -s -- "$candidate" "$snapshot"; then
    printf 'Upstream snapshot is current: %s\n' "$snapshot"
    exit 0
fi

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
    return (
        app.get("short_version", "missing"),
        app.get("bundle_version", "missing"),
        artifact.get("sha256", "missing"),
    )

print("Upstream snapshot drift:")
print("  previous: version=%s build=%s sha256=%s" % identity(old))
print("  candidate: version=%s build=%s sha256=%s" % identity(new))
old_bundles = set(old.get("application", {}).get("resource_bundles", []))
new_bundles = set(new.get("application", {}).get("resource_bundles", []))
print("  resource bundles: +%d -%d" % (len(new_bundles - old_bundles), len(old_bundles - new_bundles)))
old_plugins = set(old.get("application", {}).get("bundled_plugins", []))
new_plugins = set(new.get("application", {}).get("bundled_plugins", []))
print("  bundled plugins: +%d -%d" % (len(new_plugins - old_plugins), len(old_plugins - new_plugins)))
PY

if [ "$check_only" -eq 1 ]; then
    die "snapshot is stale; run scripts/refresh-upstream-snapshot.sh"
fi

publish="$(mktemp --tmpdir="$(dirname -- "$snapshot")" .upstream-snapshot.XXXXXX)"
cleanup() {
    rm -f -- "$publish"
}
trap cleanup EXIT HUP INT TERM
install -m 0644 -- "$candidate" "$publish"
mv -f -- "$publish" "$snapshot"
trap - EXIT HUP INT TERM
printf 'Updated upstream snapshot: %s\n' "$snapshot"
