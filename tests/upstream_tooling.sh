#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSPECTOR="$REPO_DIR/scripts/inspect-upstream.py"
FETCHER="$REPO_DIR/scripts/fetch-upstream.sh"
OFFICIAL_URL="https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT HUP INT TERM

fail() {
    printf 'upstream_tooling: %s\n' "$*" >&2
    exit 1
}

FIXTURE_DIR="$TMP_DIR/fixture"
mkdir -p "$FIXTURE_DIR"

FIXTURE_DIR="$FIXTURE_DIR" python3 - <<'PY'
import os
from pathlib import Path
import plistlib
import struct

root = Path(os.environ["FIXTURE_DIR"])
(root / "fixture.dmg").write_bytes(b"synthetic-dmg-for-command-isolation-tests\n")
plist = {
    "CFBundleDisplayName": "ChatGPT",
    "CFBundleExecutable": "ChatGPT",
    "CFBundleIdentifier": "com.openai.chat",
    "CFBundleShortVersionString": "1.2026.160",
    "CFBundleSupportedPlatforms": ["MacOSX"],
    "CFBundleURLTypes": [
        {"CFBundleURLSchemes": ["chatgpt", "openai", "com.openai.chat"]}
    ],
    "CFBundleVersion": "1781312926",
    "LSMinimumSystemVersion": "14.0",
    "NSCameraUsageDescription": "fixture camera description",
    "NSMicrophoneUsageDescription": "fixture microphone description",
    "OAIBuildTimestamp": "1781313038",
    "OAICommitHash": "7e514a4ed5",
    "SUPublicEDKey": "fixture-public-key",
}
(root / "Info.plist").write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_BINARY))

def macho(file_type: int) -> bytes:
    # Little-endian 64-bit Mach-O, CPU_TYPE_ARM64.
    return struct.pack(
        "<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, file_type, 0, 0, 0, 0
    )

(root / "ChatGPT").write_bytes(macho(2))
(root / "ChatGPT.framework").write_bytes(macho(6))
(root / "libswiftCompatibilitySpan.dylib").write_bytes(macho(6))
PY

FAKE_7Z="$TMP_DIR/fake-7z"
cat >"$FAKE_7Z" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

mode="${1:-}"
shift || true
dmg=""
for argument in "$@"; do
    case "$argument" in
        *.dmg|*.dmg.part) dmg="$argument" ;;
    esac
done

if [ "$mode" = "t" ]; then
    case "$(basename -- "$dmg")" in
        bad.dmg) printf 'fixture corruption\n' >&2; exit 2 ;;
    esac
    printf 'Everything is Ok\n'
    exit 0
fi

if [ "$mode" = "l" ]; then
    info_size="$(stat -c %s -- "$FIXTURE_DIR/Info.plist")"
    main_size="$(stat -c %s -- "$FIXTURE_DIR/ChatGPT")"
    framework_size="$(stat -c %s -- "$FIXTURE_DIR/ChatGPT.framework")"
    swift_size="$(stat -c %s -- "$FIXTURE_DIR/libswiftCompatibilitySpan.dylib")"
    printf '%s\n' \
        'Path = fixture.dmg' \
        'Type = Dmg' \
        'Physical Size = 40' \
        '----------' \
        'Path = ChatGPT Installer' \
        'Folder = +' \
        'Size = ' \
        '' \
        'Path = ChatGPT Installer/ChatGPT.app' \
        'Folder = +' \
        'Size = ' \
        '' \
        'Path = ChatGPT Installer/ChatGPT.app/Contents/Info.plist' \
        'Folder = -' \
        "Size = $info_size" \
        '' \
        'Path = ChatGPT Installer/ChatGPT.app/Contents/MacOS/ChatGPT' \
        'Folder = -' \
        "Size = $main_size" \
        '' \
        'Path = ChatGPT Installer/ChatGPT.app/Contents/Frameworks/ChatGPT.framework/Versions/A/ChatGPT' \
        'Folder = -' \
        "Size = $framework_size" \
        '' \
        'Path = ChatGPT Installer/ChatGPT.app/Contents/Frameworks/libswiftCompatibilitySpan.dylib' \
        'Folder = -' \
        "Size = $swift_size" \
        '' \
        'Path = ChatGPT Installer/ChatGPT.app/Contents/Frameworks/ChatGPT.framework/Versions/A/Resources/ChatGPTAutomation_ChatGPTAutomation.bundle' \
        'Folder = +' \
        'Size = ' \
        '' \
        'Path = ChatGPT Installer/ChatGPT.app/Contents/Frameworks/ChatGPT.framework/Versions/A/Resources/ChatGPTPresentation_ChatGPTPresentation.bundle' \
        'Folder = +' \
        'Size = ' \
        ''
    case "$(basename -- "$dmg")" in
        electron.dmg)
            printf '%s\n' \
                'Path = ChatGPT Installer/ChatGPT.app/Contents/Resources/app.asar' \
                'Folder = -' \
                'Size = 1' \
                '' \
                'Path = ChatGPT Installer/ChatGPT.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework' \
                'Folder = -' \
                "Size = $framework_size" \
                ''
            ;;
    esac
    exit 0
fi

if [ "$mode" = "e" ]; then
    member="${!#}"
    case "$member" in
        */Contents/Info.plist) exec cat "$FIXTURE_DIR/Info.plist" ;;
        */Contents/MacOS/ChatGPT) exec cat "$FIXTURE_DIR/ChatGPT" ;;
        */ChatGPT.framework/Versions/A/ChatGPT) exec cat "$FIXTURE_DIR/ChatGPT.framework" ;;
        */Electron\ Framework.framework/Versions/A/Electron\ Framework) exec cat "$FIXTURE_DIR/ChatGPT.framework" ;;
        */libswiftCompatibilitySpan.dylib) exec cat "$FIXTURE_DIR/libswiftCompatibilitySpan.dylib" ;;
        *) printf 'unexpected fixture extraction: %s\n' "$member" >&2; exit 3 ;;
    esac
fi

printf 'unexpected fake 7z mode: %s\n' "$mode" >&2
exit 4
SH
chmod +x "$FAKE_7Z"

DMG="$FIXTURE_DIR/fixture.dmg"
DMG_SIZE="$(stat -c %s -- "$DMG")"
HEADERS="$TMP_DIR/response.headers"
cat >"$HEADERS" <<EOF
HTTP/2 200
content-type: application/x-apple-diskimage
content-length: $DMG_SIZE
etag: fixture-etag
last-modified: Mon, 22 Jun 2026 16:48:02 GMT
accept-ranges: bytes

EOF

SNAPSHOT_ONE="$TMP_DIR/snapshot-one.json"
SNAPSHOT_TWO="$TMP_DIR/snapshot-two.json"
CHATGPT_WORK_7Z="$FAKE_7Z" FIXTURE_DIR="$FIXTURE_DIR" \
    python3 "$INSPECTOR" \
        --dmg "$DMG" \
        --source-url "$OFFICIAL_URL" \
        --headers "$HEADERS" >"$SNAPSHOT_ONE"
CHATGPT_WORK_7Z="$FAKE_7Z" FIXTURE_DIR="$FIXTURE_DIR" \
    python3 "$INSPECTOR" \
        --dmg "$DMG" \
        --source-url "$OFFICIAL_URL" \
        --headers "$HEADERS" >"$SNAPSHOT_TWO"
cmp -s "$SNAPSHOT_ONE" "$SNAPSHOT_TWO" || fail "inspector output is not deterministic"

python3 - "$SNAPSHOT_ONE" "$DMG_SIZE" <<'PY'
import json
import sys

snapshot = json.load(open(sys.argv[1], encoding="utf-8"))
assert snapshot["schema_version"] == 3
assert snapshot["artifact"]["size"] == int(sys.argv[2])
assert snapshot["artifact"]["archive_format"] == "dmg"
assert len(snapshot["artifact"]["sha256"]) == 64
assert snapshot["application"]["implementation"] == "native-macos"
assert snapshot["application"]["architectures"] == ["arm64"]
assert snapshot["application"]["short_version"] == "1.2026.160"
assert snapshot["application"]["minimum_system_version"] == "14.0"
assert snapshot["application"]["electron_markers"] == []
assert snapshot["application"]["bundled_plugins"] == []
assert "Mach-O" in snapshot["application"]["native_markers"]
assert snapshot["application"]["embedded_components"] == []
assert snapshot["application"]["privacy_usage_description_keys"] == [
    "NSCameraUsageDescription",
    "NSMicrophoneUsageDescription",
]
assert snapshot["application"]["resource_bundles"] == [
    "ChatGPTAutomation_ChatGPTAutomation.bundle",
    "ChatGPTPresentation_ChatGPTPresentation.bundle",
]
assert snapshot["application"]["observed_feature_modules"] == [
    {
        "bundle": "ChatGPTAutomation_ChatGPTAutomation.bundle",
        "capability": "automations",
    },
    {
        "bundle": "ChatGPTPresentation_ChatGPTPresentation.bundle",
        "capability": "presentations",
    },
]
assert snapshot["source"]["http"]["etag"] == "fixture-etag"
assert snapshot["source"]["http"]["content_length"] == int(sys.argv[2])
assert snapshot["verification"]["artifact_executed"] is False
assert len(snapshot["binaries"]) == 3
assert {item["kind"] for item in snapshot["binaries"]} == {
    "executable", "dynamic-library"
}
PY

ELECTRON_DMG="$TMP_DIR/electron.dmg"
cp -- "$DMG" "$ELECTRON_DMG"
CHATGPT_WORK_7Z="$FAKE_7Z" FIXTURE_DIR="$FIXTURE_DIR" \
    python3 "$INSPECTOR" --dmg "$ELECTRON_DMG" \
        --header "Content-Length:$DMG_SIZE" >"$TMP_DIR/electron.json"
python3 - "$TMP_DIR/electron.json" <<'PY'
import json
import sys
snapshot = json.load(open(sys.argv[1], encoding="utf-8"))
assert snapshot["application"]["implementation"] == "electron"
assert snapshot["application"]["electron_markers"] == [
    "Electron Framework.framework", "app.asar"
]
PY

if CHATGPT_WORK_7Z="$FAKE_7Z" FIXTURE_DIR="$FIXTURE_DIR" \
    python3 "$INSPECTOR" --dmg "$DMG" --source-url "http://example.invalid/a.dmg" \
        >/dev/null 2>&1; then
    fail "inspector accepted a non-HTTPS source"
fi
if CHATGPT_WORK_7Z="$FAKE_7Z" FIXTURE_DIR="$FIXTURE_DIR" \
    python3 "$INSPECTOR" --dmg "$DMG" --source-url "https://example.invalid/a.dmg" \
        >/dev/null 2>&1; then
    fail "inspector accepted a non-allowlisted source"
fi
if CHATGPT_WORK_7Z="$FAKE_7Z" FIXTURE_DIR="$FIXTURE_DIR" \
    python3 "$INSPECTOR" --dmg "$DMG" --header 'Content-Length:1' \
        >/dev/null 2>&1; then
    fail "inspector accepted a mismatched Content-Length"
fi

BAD_DMG="$TMP_DIR/bad.dmg"
cp -- "$DMG" "$BAD_DMG"
if CHATGPT_WORK_7Z="$FAKE_7Z" FIXTURE_DIR="$FIXTURE_DIR" \
    python3 "$INSPECTOR" --dmg "$BAD_DMG" >/dev/null 2>&1; then
    fail "inspector accepted a DMG rejected by 7z"
fi

FAKE_CURL="$TMP_DIR/fake-curl"
cat >"$FAKE_CURL" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' "$*" >>"$CURL_LOG"
head_request=0
resume=0
headers=""
output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --head) head_request=1; shift ;;
        --continue-at) resume=1; shift 2 ;;
        --dump-header) headers="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --retry|--retry-delay|--connect-timeout|--proto|--header|--max-time|--speed-limit|--speed-time)
            shift 2
            ;;
        --silent|--show-error|--fail|--retry-all-errors) shift ;;
        *) shift ;;
    esac
done

size="$(stat -c %s -- "$FIXTURE_DMG")"
if [ "$head_request" -eq 1 ]; then
    printf 'HEAD\n' >>"$CURL_LOG"
    cat >"$headers" <<EOF
HTTP/2 200
content-type: application/x-apple-diskimage
content-length: $size
etag: fixture-etag
last-modified: Mon, 22 Jun 2026 16:48:02 GMT
accept-ranges: bytes

EOF
    exit 0
fi

printf 'GET\n' >>"$CURL_LOG"
if [ "$resume" -eq 1 ]; then
    offset="$(stat -c %s -- "$output")"
    dd if="$FIXTURE_DMG" bs=1 skip="$offset" status=none >>"$output"
    status=206
else
    cp -- "$FIXTURE_DMG" "$output"
    status=200
fi
printf 'HTTP/2 %s\n\n' "$status" >"$headers"
SH
chmod +x "$FAKE_CURL"

ONLINE_DIR="$TMP_DIR/online"
CACHE_DIR="$TMP_DIR/cache"
mkdir -p "$ONLINE_DIR" "$CACHE_DIR"
ONLINE_DMG="$ONLINE_DIR/online.dmg"
ONLINE_METADATA="$ONLINE_DIR/online.json"
ONLINE_HEADERS="$ONLINE_DIR/online.headers"
CURL_LOG="$TMP_DIR/curl.log"
touch "$CURL_LOG"

# The production default must reject the small legacy/classic wrapper class
# before attempting a download. Fixtures opt into a one-byte floor below.
if CHATGPT_WORK_CACHE_DIR="$TMP_DIR/undersized-cache" \
    CHATGPT_WORK_CURL="$FAKE_CURL" \
    CHATGPT_WORK_7Z="$FAKE_7Z" \
    CURL_LOG="$CURL_LOG" \
    FIXTURE_DMG="$DMG" \
    FIXTURE_DIR="$FIXTURE_DIR" \
    "$FETCHER" --output "$TMP_DIR/undersized.dmg" \
        --metadata "$TMP_DIR/undersized.json" \
        --headers "$TMP_DIR/undersized.headers" >/dev/null 2>&1; then
    fail "fetcher accepted an undersized upstream artifact"
fi
[ "$(grep -c '^GET$' "$CURL_LOG" || true)" -eq 0 ] || \
    fail "fetcher downloaded an undersized upstream artifact"

# Seed a matching partial and state to exercise If-Range resume behavior.
head -c 9 "$DMG" >"$CACHE_DIR/online.dmg.part"
cat >"$CACHE_DIR/download.state" <<EOF
url=$OFFICIAL_URL
etag=fixture-etag
last_modified=Mon, 22 Jun 2026 16:48:02 GMT
content_length=$DMG_SIZE
EOF

CHATGPT_WORK_CACHE_DIR="$CACHE_DIR" \
CHATGPT_WORK_MIN_UPSTREAM_BYTES=1 \
CHATGPT_WORK_CURL="$FAKE_CURL" \
CHATGPT_WORK_7Z="$FAKE_7Z" \
CURL_LOG="$CURL_LOG" \
FIXTURE_DMG="$DMG" \
FIXTURE_DIR="$FIXTURE_DIR" \
    "$FETCHER" --output "$ONLINE_DMG" --metadata "$ONLINE_METADATA" \
        --headers "$ONLINE_HEADERS"

cmp -s "$DMG" "$ONLINE_DMG" || fail "resumed download differs from fixture"
[ ! -e "$CACHE_DIR/online.dmg.part" ] || fail "partial remained after successful fetch"
[ ! -e "$CACHE_DIR/download.state" ] || fail "download state remained after successful fetch"
grep -q -- '--retry 4' "$CURL_LOG" || fail "fetcher did not configure curl retries"
grep -q -- '--connect-timeout 15' "$CURL_LOG" || fail "fetcher did not configure connect timeout"
grep -q -- '--proto =https' "$CURL_LOG" || fail "fetcher did not constrain curl to HTTPS"
grep -q -- '--continue-at -' "$CURL_LOG" || fail "fetcher did not resume the partial"
grep -q -- 'If-Range: fixture-etag' "$CURL_LOG" || fail "fetcher omitted If-Range"
[ "$(grep -c '^GET$' "$CURL_LOG")" -eq 1 ] || fail "unexpected download request count"

# A second online run must validate the ETag/hash cache and perform HEAD only.
CHATGPT_WORK_CACHE_DIR="$CACHE_DIR" \
CHATGPT_WORK_MIN_UPSTREAM_BYTES=1 \
CHATGPT_WORK_CURL="$FAKE_CURL" \
CHATGPT_WORK_7Z="$FAKE_7Z" \
CURL_LOG="$CURL_LOG" \
FIXTURE_DMG="$DMG" \
FIXTURE_DIR="$FIXTURE_DIR" \
    "$FETCHER" --output "$ONLINE_DMG" --metadata "$ONLINE_METADATA" \
        --headers "$ONLINE_HEADERS"
[ "$(grep -c '^GET$' "$CURL_LOG")" -eq 1 ] || fail "ETag cache triggered a second download"

FAIL_CURL="$TMP_DIR/fail-curl"
cat >"$FAIL_CURL" <<'SH'
#!/usr/bin/env bash
printf 'offline mode invoked curl\n' >&2
exit 99
SH
chmod +x "$FAIL_CURL"
CHATGPT_WORK_CACHE_DIR="$TMP_DIR/offline-cache" \
CHATGPT_WORK_MIN_UPSTREAM_BYTES=1 \
CHATGPT_WORK_CURL="$FAIL_CURL" \
CHATGPT_WORK_7Z="$FAKE_7Z" \
FIXTURE_DIR="$FIXTURE_DIR" \
    "$FETCHER" --offline --output "$DMG" \
        --metadata "$TMP_DIR/offline.json" --headers "$HEADERS"

if CHATGPT_WORK_CACHE_DIR="$TMP_DIR/rejected-cache" \
    CHATGPT_WORK_CURL="$FAIL_CURL" "$FETCHER" --offline --output "$DMG" \
        --url 'http://persistent.oaistatic.com/sidekick/public/ChatGPT.dmg' \
        >/dev/null 2>&1; then
    fail "fetcher accepted HTTP"
fi
if CHATGPT_WORK_CACHE_DIR="$TMP_DIR/rejected-cache" \
    CHATGPT_WORK_CURL="$FAIL_CURL" "$FETCHER" --offline --output "$DMG" \
        --url 'https://example.invalid/ChatGPT.dmg' >/dev/null 2>&1; then
    fail "fetcher accepted a non-allowlisted host"
fi

git -C "$REPO_DIR" check-ignore -q ChatGPT-work.dmg || fail "ChatGPT-work.dmg is not gitignored"

printf 'upstream_tooling: all tests passed\n'
