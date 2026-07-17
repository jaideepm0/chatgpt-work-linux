#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
official_url=https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg
snapshot=${CHATGPT_WORK_UPSTREAM_SNAPSHOT:-"$repo_root/docs/upstream-snapshot.json"}
cache_dir="${CHATGPT_WORK_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/chatgpt-work-linux/upstream}"
result="$cache_dir/check-result.json"
headers="$cache_dir/check-response.headers"
minimum_interval=${CHATGPT_WORK_UPDATE_CHECK_INTERVAL_SECONDS:-21600}
minimum_size=${CHATGPT_WORK_MIN_UPSTREAM_BYTES:-$((500 * 1024 * 1024))}
curl_bin=${CHATGPT_WORK_CURL:-curl}
force=0
json=0

usage() {
  cat <<'EOF'
Usage: scripts/check-upstream.sh [--force] [--json]

Perform one metadata-only HEAD check against the exact official unified DMG.
Results are cached for six hours by default; --force bypasses that cache.
This command never downloads or installs an application.
EOF
}

fail() {
  printf 'check-upstream: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --force) force=1 ;;
    --json) json=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done
[[ $minimum_interval =~ ^[0-9]+$ ]] || fail 'check interval must be an integer'
[[ $minimum_size =~ ^[0-9]+$ ]] || fail 'minimum upstream size must be an integer'
(( minimum_size < 2 * 1024 * 1024 * 1024 )) || fail 'minimum upstream size exceeds safety limit'
[[ -f $snapshot ]] || fail "missing reviewed snapshot: $snapshot"
command -v "$curl_bin" >/dev/null 2>&1 || fail "curl not found: $curl_bin"
mkdir -p -- "$cache_dir"
chmod 0700 "$cache_dir"
exec {lock_fd}>"$cache_dir/check.lock"
flock "$lock_fd"

emit() {
  local cached=$1
  if [[ $json -eq 1 ]]; then
    python3 - "$result" "$cached" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
value["cached"] = sys.argv[2] == "true"
print(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
  else
    python3 - "$result" "$cached" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
suffix = " (cached)" if sys.argv[2] == "true" else ""
print(f"upstream_status={value['status']}{suffix}")
print(f"remote_last_modified={value['remote']['lastModified']}")
print(f"remote_size_bytes={value['remote']['sizeBytes']}")
print(f"remote_etag={value['remote']['etag']}")
PY
  fi
}

now=$(date +%s)
if [[ $force -eq 0 && -s $result ]]; then
  checked=$(python3 - "$result" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        print(int(json.load(handle)["checkedAtEpoch"]))
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
    print(0)
PY
)
  if (( now >= checked && now - checked < minimum_interval )); then
    emit true
    exit 0
  fi
fi

headers_part="$headers.part"
result_part="$result.part"
cleanup() {
  rm -f -- "$headers_part" "$result_part"
}
trap cleanup EXIT HUP INT TERM
"$curl_bin" --silent --show-error --fail --retry 2 --retry-all-errors \
  --retry-delay 2 --connect-timeout 15 --max-time 60 --proto '=https' \
  --header 'Accept-Encoding: identity' --head --dump-header "$headers_part" \
  --output /dev/null "$official_url"

header_value() {
  awk -v wanted="${1,,}" '
    { sub(/\r$/, ""); name=$0; sub(/:.*/, "", name); if (tolower(name)==wanted) {
      value=substr($0, length(name)+2); sub(/^[[:space:]]+/, "", value); found=value
    }} END {print found}' "$headers_part"
}
status=$(awk '/^HTTP\// {value=$2} END {print value}' "$headers_part")
etag=$(header_value etag)
last_modified=$(header_value last-modified)
content_length=$(header_value content-length)
content_type=$(header_value content-type)
[[ $status == 200 ]] || fail "unexpected HTTP status: ${status:-missing}"
[[ $content_length =~ ^[0-9]+$ ]] || fail 'missing or invalid Content-Length'
(( content_length > minimum_size && content_length <= 2 * 1024 * 1024 * 1024 )) || \
  fail "remote size is outside unified DMG bounds: $content_length"
[[ $content_type == application/x-apple-diskimage ]] || fail "unexpected Content-Type: $content_type"
[[ -n $etag && -n $last_modified ]] || fail 'missing upstream identity headers'

python3 - "$snapshot" "$result_part" "$now" "$etag" "$last_modified" "$content_length" "$official_url" <<'PY'
import json
import sys
snapshot_path, result_path, checked, etag, modified, size, url = sys.argv[1:]
with open(snapshot_path, encoding="utf-8") as handle:
    snapshot = json.load(handle)
source = snapshot["source"]
http = source["http"]
current = (
    source["url"] == url
    and http.get("etag") == etag
    and http.get("last_modified") == modified
    and int(http.get("content_length", -1)) == int(size)
)
value = {
    "schemaVersion": 1,
    "checkedAtEpoch": int(checked),
    "status": "current" if current else "update-available",
    "url": url,
    "remote": {"etag": etag, "lastModified": modified, "sizeBytes": int(size)},
    "reviewed": {
        "version": snapshot["application"]["short_version"],
        "etag": http.get("etag"),
        "lastModified": http.get("last_modified"),
        "sizeBytes": int(http.get("content_length", -1)),
    },
}
with open(result_path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
mv -f -- "$headers_part" "$headers"
mv -f -- "$result_part" "$result"
trap - EXIT HUP INT TERM
emit false
