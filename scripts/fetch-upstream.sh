#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

OFFICIAL_URL="https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg"
URL="$OFFICIAL_URL"
OUTPUT="$REPO_DIR/ChatGPT-work.dmg"
CACHE_DIR="${CHATGPT_WORK_CACHE_DIR:-$REPO_DIR/.cache/upstream}"
METADATA="$CACHE_DIR/upstream-snapshot.json"
HEADERS_FILE="$CACHE_DIR/response.headers"
OFFLINE=0
FORCE=0
MAX_UPSTREAM_BYTES=$((2 * 1024 * 1024 * 1024))
MIN_UPSTREAM_BYTES=${CHATGPT_WORK_MIN_UPSTREAM_BYTES:-$((500 * 1024 * 1024))}

CURL_BIN="${CHATGPT_WORK_CURL:-curl}"
PYTHON_BIN="${CHATGPT_WORK_PYTHON:-python3}"
INSPECTOR="$SCRIPT_DIR/inspect-upstream.py"

usage() {
    cat <<'EOF'
Usage: scripts/fetch-upstream.sh [OPTIONS]

Fetch and inspect the allowlisted official unified ChatGPT macOS artifact.

Options:
  --output PATH       DMG destination (default: ./ChatGPT-work.dmg)
  --metadata PATH     deterministic inspection JSON destination
  --headers PATH      raw HEAD response headers destination/input
  --url URL           upstream URL; currently only the official URL is allowed
  --offline           inspect --output without making any network request
  --force             bypass a matching local ETag/hash cache
  -h, --help          show this help

The proprietary DMG is never executed or added to a package. Downloads are
resumed in an ignored .part file, validated, then atomically renamed.
EOF
}

die() {
    printf 'fetch-upstream: %s\n' "$*" >&2
    exit 1
}

need_value() {
    [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            need_value "$@"
            OUTPUT="$2"
            shift 2
            ;;
        --metadata)
            need_value "$@"
            METADATA="$2"
            shift 2
            ;;
        --headers)
            need_value "$@"
            HEADERS_FILE="$2"
            shift 2
            ;;
        --url)
            need_value "$@"
            URL="$2"
            shift 2
            ;;
        --offline)
            OFFLINE=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            [ "$#" -eq 0 ] || die "unexpected positional arguments: $*"
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[ "$URL" = "$OFFICIAL_URL" ] || die "URL is not on the compiled allowlist: $URL"
case "$URL" in
    https://*) ;;
    *) die "upstream URL must use HTTPS" ;;
esac
case "$MIN_UPSTREAM_BYTES" in
    ''|*[!0-9]*) die "CHATGPT_WORK_MIN_UPSTREAM_BYTES must be an integer" ;;
esac
[ "$MIN_UPSTREAM_BYTES" -lt "$MAX_UPSTREAM_BYTES" ] || \
    die "minimum upstream size must be below the safety limit"

command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "Python 3 not found: $PYTHON_BIN"
[ -f "$INSPECTOR" ] || die "missing inspector: $INSPECTOR"

mkdir -p -- "$(dirname -- "$OUTPUT")" "$(dirname -- "$METADATA")" \
    "$(dirname -- "$HEADERS_FILE")" "$CACHE_DIR"

if [ "$OUTPUT" = "$METADATA" ] || [ "$OUTPUT" = "$HEADERS_FILE" ] || \
   [ "$METADATA" = "$HEADERS_FILE" ]; then
    die "output, metadata, and headers paths must be distinct"
fi

# Serialize updates so concurrent launchers cannot combine partial downloads.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$CACHE_DIR/fetch.lock"
    flock 9
fi

METADATA_PART="$METADATA.part"
HEAD_PART="$HEADERS_FILE.part"
GET_HEADERS_PART="$CACHE_DIR/get-response.headers.part"
STATE_FILE="$CACHE_DIR/download.state"
STATE_PART="$STATE_FILE.part"

# Keep default partials under ignored .cache while retaining an atomic rename.
if [ "$(stat -c %d -- "$CACHE_DIR")" = "$(stat -c %d -- "$(dirname -- "$OUTPUT")")" ]; then
    DOWNLOAD_PART="$CACHE_DIR/$(basename -- "$OUTPUT").part"
else
    DOWNLOAD_PART="$OUTPUT.part"
fi

cleanup() {
    rm -f -- "$METADATA_PART" "$HEAD_PART" "$GET_HEADERS_PART" "$STATE_PART"
}
trap cleanup EXIT HUP INT TERM

inspect_to_metadata() {
    local artifact_path="$1"
    local headers_path="${2:-}"
    local -a command=(
        "$PYTHON_BIN" "$INSPECTOR"
        --dmg "$artifact_path"
        --artifact-name "$(basename -- "$OUTPUT")"
        --source-url "$URL"
    )
    if [ -n "$headers_path" ] && [ -f "$headers_path" ]; then
        command+=(--headers "$headers_path")
    fi
    if ! "${command[@]}" >"$METADATA_PART"; then
        return 1
    fi
}

if [ "$OFFLINE" -eq 1 ]; then
    [ -f "$OUTPUT" ] || die "offline DMG does not exist: $OUTPUT"
    inspect_to_metadata "$OUTPUT" "$HEADERS_FILE"
    mv -f -- "$METADATA_PART" "$METADATA"
    printf 'Inspected offline artifact: %s\nMetadata: %s\n' "$OUTPUT" "$METADATA" >&2
    exit 0
fi

command -v "$CURL_BIN" >/dev/null 2>&1 || die "curl not found: $CURL_BIN"

curl_common=(
    --silent
    --show-error
    --fail
    --retry 4
    --retry-all-errors
    --retry-delay 2
    --connect-timeout 15
    --proto '=https'
    --header 'Accept-Encoding: identity'
)

"$CURL_BIN" "${curl_common[@]}" \
    --max-time 60 \
    --head \
    --dump-header "$HEAD_PART" \
    --output /dev/null \
    "$URL"

header_value() {
    local wanted="${1,,}"
    awk -v wanted="$wanted" '
        {
            sub(/\r$/, "")
            split($0, fields, ":")
            name = tolower(fields[1])
            if (name == wanted) {
                value = substr($0, length(fields[1]) + 2)
                sub(/^[[:space:]]+/, "", value)
                found = value
            }
        }
        END { print found }
    ' "$HEAD_PART"
}

HTTP_STATUS="$(awk '/^HTTP\// { status=$2 } END { print status }' "$HEAD_PART")"
[ "$HTTP_STATUS" = "200" ] || die "unexpected upstream HEAD status: ${HTTP_STATUS:-missing}"

ETAG="$(header_value etag)"
LAST_MODIFIED="$(header_value last-modified)"
CONTENT_LENGTH="$(header_value content-length)"
CONTENT_TYPE="$(header_value content-type)"

case "$CONTENT_LENGTH" in
    ''|*[!0-9]*) die "upstream response has invalid Content-Length: ${CONTENT_LENGTH:-missing}" ;;
esac
[ "$CONTENT_LENGTH" -gt 0 ] || die "upstream artifact is empty"
[ "$CONTENT_LENGTH" -gt "$MIN_UPSTREAM_BYTES" ] || \
    die "upstream artifact is too small for the unified Work app: $CONTENT_LENGTH bytes"
[ "$CONTENT_LENGTH" -le "$MAX_UPSTREAM_BYTES" ] || \
    die "upstream artifact exceeds the $MAX_UPSTREAM_BYTES byte safety limit"
[ "$CONTENT_TYPE" = "application/x-apple-diskimage" ] || \
    die "unexpected upstream Content-Type: ${CONTENT_TYPE:-missing}"
[ -n "$ETAG" ] || die "upstream response did not provide an ETag"
[ -n "$LAST_MODIFIED" ] || die "upstream response did not provide Last-Modified"

cache_matches_remote() {
    [ -f "$OUTPUT" ] && [ -f "$METADATA" ] || return 1
    "$PYTHON_BIN" - "$OUTPUT" "$METADATA" "$URL" "$ETAG" "$LAST_MODIFIED" "$CONTENT_LENGTH" <<'PY'
import hashlib
import json
import os
import sys

artifact, metadata_path, url, etag, last_modified, content_length = sys.argv[1:]
try:
    metadata = json.load(open(metadata_path, encoding="utf-8"))
    recorded = metadata["artifact"]
    source = metadata["source"]
    http = source["http"]
    if source["url"] != url:
        raise ValueError
    if http.get("etag") != etag or http.get("last_modified") != last_modified:
        raise ValueError
    if int(http.get("content_length", -1)) != int(content_length):
        raise ValueError
    if os.path.getsize(artifact) != int(recorded["size"]):
        raise ValueError
    digest = hashlib.sha256()
    with open(artifact, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != recorded["sha256"]:
        raise ValueError
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

if [ "$FORCE" -eq 0 ] && cache_matches_remote; then
    inspect_to_metadata "$OUTPUT" "$HEAD_PART"
    mv -f -- "$HEAD_PART" "$HEADERS_FILE"
    mv -f -- "$METADATA_PART" "$METADATA"
    rm -f -- "$DOWNLOAD_PART" "$STATE_FILE"
    printf 'Upstream artifact unchanged (ETag %s): %s\nMetadata: %s\n' \
        "$ETAG" "$OUTPUT" "$METADATA" >&2
    exit 0
fi

EXPECTED_STATE="url=$URL
etag=$ETAG
last_modified=$LAST_MODIFIED
content_length=$CONTENT_LENGTH"
printf '%s\n' "$EXPECTED_STATE" >"$STATE_PART"

if [ "$FORCE" -eq 1 ] || \
   { [ -f "$DOWNLOAD_PART" ] && [ ! -f "$STATE_FILE" ]; } || \
   { [ -f "$STATE_FILE" ] && ! cmp -s -- "$STATE_PART" "$STATE_FILE"; }; then
    rm -f -- "$DOWNLOAD_PART"
fi
mv -f -- "$STATE_PART" "$STATE_FILE"

resume_size=0
if [ -f "$DOWNLOAD_PART" ]; then
    resume_size="$(stat -c %s -- "$DOWNLOAD_PART")"
    if [ "$resume_size" -gt "$CONTENT_LENGTH" ]; then
        rm -f -- "$DOWNLOAD_PART"
        resume_size=0
    fi
fi

if [ "$resume_size" -lt "$CONTENT_LENGTH" ]; then
    download_args=(
        "${curl_common[@]}"
        --max-time 1800
        --speed-limit 1024
        --speed-time 90
        --dump-header "$GET_HEADERS_PART"
        --output "$DOWNLOAD_PART"
    )
    if [ "$resume_size" -gt 0 ]; then
        download_args+=(--continue-at - --header "If-Range: $ETAG")
    fi

    "$CURL_BIN" "${download_args[@]}" "$URL"

    GET_STATUS="$(awk '/^HTTP\// { status=$2 } END { print status }' "$GET_HEADERS_PART")"
    case "$GET_STATUS" in
        200|206) ;;
        *) die "unexpected upstream download status: ${GET_STATUS:-missing}" ;;
    esac
    if [ "$resume_size" -gt 0 ] && [ "$GET_STATUS" != "206" ]; then
        rm -f -- "$DOWNLOAD_PART"
        die "server did not honor the safe ranged resume; partial file was discarded"
    fi
fi

ACTUAL_SIZE="$(stat -c %s -- "$DOWNLOAD_PART")"
if [ "$ACTUAL_SIZE" -ne "$CONTENT_LENGTH" ]; then
    die "incomplete download: expected $CONTENT_LENGTH bytes, received $ACTUAL_SIZE"
fi

# The inspector performs 7z integrity/type checks, constrained extraction,
# plist parsing, Mach-O classification, and the final SHA-256 calculation.
if ! inspect_to_metadata "$DOWNLOAD_PART" "$HEAD_PART"; then
    rm -f -- "$DOWNLOAD_PART"
    die "download failed artifact inspection and was discarded"
fi

mv -f -- "$DOWNLOAD_PART" "$OUTPUT"
mv -f -- "$HEAD_PART" "$HEADERS_FILE"
mv -f -- "$METADATA_PART" "$METADATA"
rm -f -- "$STATE_FILE" "$GET_HEADERS_PART"

printf 'Fetched verified artifact: %s\nMetadata: %s\n' "$OUTPUT" "$METADATA" >&2
