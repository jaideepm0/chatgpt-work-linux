#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

source_profile="${CHATGPT_WORK_LEGACY_ELECTRON_PROFILE:-${XDG_CONFIG_HOME:-$HOME/.config}/Codex}"
target_profile="${CHATGPT_WORK_ELECTRON_PROFILE:-${XDG_STATE_HOME:-$HOME/.local/state}/chatgpt-work-linux/xdg-config/Codex}"
replace_target=0
dry_run=0

usage() {
  cat <<'EOF'
Usage: scripts/migrate-electron-profile.sh [OPTIONS]

Copy an existing Codex/ChatGPT Electron profile into the isolated Work runtime
profile. Regenerable Chromium caches are excluded. Existing target data is
never replaced unless --replace-target is explicit, and is retained as an
atomic backup when replacement is requested.

  --source PATH       source Electron profile (default: ~/.config/Codex)
  --target PATH       isolated target profile
  --replace-target    back up and replace a non-empty target profile
  --dry-run           validate and report without changing files
  -h, --help          show this help
EOF
}

die() {
  printf 'migrate-electron-profile: %s\n' "$*" >&2
  exit 1
}

need_value() {
  [[ $# -ge 2 && -n $2 ]] || die "$1 requires a value"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --source) need_value "$@"; source_profile=$2; shift 2 ;;
    --target) need_value "$@"; target_profile=$2; shift 2 ;;
    --replace-target) replace_target=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

source_profile=$(realpath -m -- "$source_profile")
target_profile=$(realpath -m -- "$target_profile")
[[ $source_profile == /* && $source_profile != / ]] || die 'source path must be absolute and non-root'
[[ $target_profile == /* && $target_profile != / ]] || die 'target path must be absolute and non-root'
[[ $source_profile != "$target_profile" ]] || die 'source and target profiles are identical'
[[ ! -L $source_profile && ! -L $target_profile ]] || die 'profile roots must not be symbolic links'

if [[ ! -d $source_profile ]]; then
  printf 'No prior Electron profile found at %s; nothing to migrate.\n' "$source_profile"
  exit 0
fi

validate_profile() {
  python3 - "$1" <<'PY'
import json
from pathlib import Path
import sqlite3
import sys

root = Path(sys.argv[1])
if not root.is_dir() or root.is_symlink():
    raise SystemExit(f"profile is not a real directory: {root}")

identity_files = [root / "Local State", root / "Preferences"]
if not any(path.is_file() for path in identity_files):
    raise SystemExit(f"profile has no Chromium identity metadata: {root}")
for path in identity_files:
    if path.is_file():
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
        if not isinstance(value, dict):
            raise SystemExit(f"profile JSON is not an object: {path}")

cookie_databases = sorted(root.rglob("Cookies"))
for path in cookie_databases:
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"unsafe cookie database path: {path}")
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        result = connection.execute("PRAGMA quick_check").fetchone()
    finally:
        connection.close()
    if result != ("ok",):
        raise SystemExit(f"cookie database failed integrity check: {path}")

print(f"files={sum(1 for p in root.rglob('*') if p.is_file())} cookies={len(cookie_databases)}")
PY
}

source_summary=$(validate_profile "$source_profile") || die 'source profile validation failed'
state_dir=$(dirname -- "$(dirname -- "$target_profile")")
lock_path="$state_dir/electron-profile-migration.lock"
marker_path="$state_dir/electron-profile-migration.json"
backup_root="$state_dir/profile-migration-backups"

# A completed one-time migration is idempotent. Do not recopy an ambient
# profile on every update; doing so could roll back newer isolated state.
if [[ $replace_target -eq 0 && -f $marker_path && -d $target_profile ]]; then
  if python3 - "$marker_path" "$source_profile" "$target_profile" <<'PY'
import json
import sys

path, source, target = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
if value.get("schemaVersion") != 1 or value.get("source") != source or value.get("target") != target:
    raise SystemExit(1)
PY
  then
    target_summary=$(validate_profile "$target_profile") || die 'migrated target profile validation failed'
    printf 'Electron profile migration already completed (%s): %s\n' "$target_summary" "$target_profile"
    exit 0
  fi
fi

target_nonempty=0
if [[ -d $target_profile ]] && find "$target_profile" -mindepth 1 -print -quit | grep -q .; then
  target_nonempty=1
fi
if [[ $target_nonempty -eq 1 && $replace_target -eq 0 ]]; then
  die "target profile already contains data: $target_profile (review it, then use --replace-target)"
fi

printf 'Source profile validated (%s): %s\n' "$source_summary" "$source_profile"
if [[ $dry_run -eq 1 ]]; then
  if [[ $target_nonempty -eq 1 ]]; then
    printf 'Dry run: the existing target would be backed up and replaced: %s\n' "$target_profile"
  else
    printf 'Dry run: the isolated target would be created: %s\n' "$target_profile"
  fi
  exit 0
fi

mkdir -p -- "$state_dir" "$(dirname -- "$target_profile")" "$backup_root"
chmod 0700 "$state_dir" "$(dirname -- "$target_profile")" "$backup_root"
exec {migration_lock_fd}>"$lock_path"
flock -n "$migration_lock_fd" || die 'another Electron profile migration is running'

# Recheck target state after acquiring the transaction lock.
target_nonempty=0
if [[ -d $target_profile ]] && find "$target_profile" -mindepth 1 -print -quit | grep -q .; then
  target_nonempty=1
fi
if [[ $target_nonempty -eq 1 && $replace_target -eq 0 ]]; then
  die "target profile already contains data: $target_profile (review it, then use --replace-target)"
fi

# Refuse a live Chromium profile. Copying SQLite/LevelDB state while Electron is
# writing it can produce a superficially valid but incomplete authentication
# profile. Run this both before and after the copy.
assert_profiles_idle() {
  local profile_file
  while IFS= read -r -d '' profile_file; do
    if fuser -s -- "$profile_file" 2>/dev/null; then
      die "profile is in use; close ChatGPT/Codex before migration: $profile_file"
    fi
  done < <(
    find "$source_profile" "$target_profile" -xdev -type f \
      \( -name Cookies -o -name LOCK -o -name 'Local State' -o -name Preferences \) \
      -print0 2>/dev/null || true
  )
}
assert_profiles_idle

stage="$(dirname -- "$target_profile")/.Codex.migrate.$$"
backup=
target_moved=0
target_published=0
transaction_complete=0
transaction_id=
failed_target=
cleanup() {
  if [[ $transaction_complete -eq 0 && $target_published -eq 1 && -d $target_profile ]]; then
    if [[ -n $transaction_id ]] && python3 - "$marker_path" "$transaction_id" <<'PY' 2>/dev/null
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
raise SystemExit(0 if value.get("transactionId") == sys.argv[2] else 1)
PY
    then
      transaction_complete=1
    else
      chmod -R u+w -- "$target_profile" 2>/dev/null || true
      failed_target="$backup_root/failed-Codex.${transaction_id:-unknown}"
      mv -T -- "$target_profile" "$failed_target" 2>/dev/null || true
    fi
  fi
  if [[ $target_moved -eq 1 && ! -e $target_profile && -n $backup && -d $backup ]]; then
    mv -T -- "$backup" "$target_profile" 2>/dev/null || true
  fi
  [[ ! -e $stage ]] || { chmod -R u+w -- "$stage" 2>/dev/null || true; rm -rf -- "$stage"; }
  rm -f -- "$marker_path.new-$$"
}
trap cleanup EXIT HUP INT TERM

mkdir -m 0700 -- "$stage"
tar -C "$source_profile" --one-file-system \
  --exclude='./Cache' --exclude='./Cache/*' \
  --exclude='*/Cache' --exclude='*/Cache/*' \
  --exclude='./Code Cache' --exclude='./Code Cache/*' \
  --exclude='*/Code Cache' --exclude='*/Code Cache/*' \
  --exclude='*/GPUCache' --exclude='*/GPUCache/*' \
  --exclude='*/DawnGraphiteCache' --exclude='*/DawnGraphiteCache/*' \
  --exclude='*/DawnWebGPUCache' --exclude='*/DawnWebGPUCache/*' \
  --exclude='*/GrShaderCache' --exclude='*/GrShaderCache/*' \
  --exclude='*/ShaderCache' --exclude='*/ShaderCache/*' \
  --exclude='./Crashpad' --exclude='./Crashpad/*' \
  --exclude='*/SingletonLock' --exclude='*/SingletonCookie' --exclude='*/SingletonSocket' \
  -cf - . | tar -C "$stage" --no-same-owner -xf -

if find "$stage" -xdev -type l -print -quit | grep -q .; then
  die 'copied profile contains an unexpected symbolic link'
fi
if find "$stage" -xdev ! -type f ! -type d -print -quit | grep -q .; then
  die 'copied profile contains an unsupported special file'
fi
stage_summary=$(validate_profile "$stage") || die 'copied profile validation failed'
assert_profiles_idle

transaction_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
if [[ $target_nonempty -eq 1 ]]; then
  backup="$backup_root/Codex.$transaction_id"
fi

python3 - "$marker_path.new-$$" "$source_profile" "$target_profile" "${backup:-}" \
  "$stage_summary" "$transaction_id" <<'PY'
from datetime import datetime, timezone
import json
import os
import sys

path, source, target, backup, summary, transaction_id = sys.argv[1:]
value = {
    "schemaVersion": 1,
    "transactionId": transaction_id,
    "completedAt": datetime.now(timezone.utc).isoformat(),
    "source": source,
    "target": target,
    "backup": backup or None,
    "copiedProfileSummary": summary,
    "excluded": ["Chromium caches", "crash reports", "singleton locks"],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.chmod(path, 0o600)
PY

if [[ -d $target_profile ]]; then
  if [[ $target_nonempty -eq 1 ]]; then
    mv -T -- "$target_profile" "$backup"
    target_moved=1
  else
    rmdir -- "$target_profile"
  fi
fi
mv -T -- "$stage" "$target_profile"
target_published=1
chmod 0700 "$target_profile"
mv -f -- "$marker_path.new-$$" "$marker_path"
transaction_complete=1
target_moved=0
target_published=0

trap - EXIT HUP INT TERM
cleanup
printf 'Migrated Electron profile into %s (%s).\n' "$target_profile" "$stage_summary"
if [[ -n $backup ]]; then
  printf 'Previous isolated profile retained at %s\n' "$backup"
fi
