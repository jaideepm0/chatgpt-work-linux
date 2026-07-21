#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d)
trap 'chmod -R u+w -- "$temporary" 2>/dev/null || true; rm -rf -- "$temporary"' EXIT HUP INT TERM
source_profile="$temporary/source/Codex"
target_profile="$temporary/state/chatgpt-work-linux/xdg-config/Codex"
mkdir -p -- "$source_profile/Partitions/codex-browser-app/Cache" "$source_profile/Local Storage/leveldb"
printf '%s\n' '{"os_crypt":{"portal":true}}' >"$source_profile/Local State"
printf '%s\n' '{"profile":{"name":"fixture"}}' >"$source_profile/Preferences"
printf '%s\n' 'persistent-state' >"$source_profile/Local Storage/leveldb/000001.ldb"
printf '%s\n' 'regenerable-cache' >"$source_profile/Partitions/codex-browser-app/Cache/cache-entry"
python3 - "$source_profile/Cookies" "$source_profile/Partitions/codex-browser-app/Cookies" <<'PY'
import sqlite3
import sys
for path in sys.argv[1:]:
    connection = sqlite3.connect(path)
    connection.execute("CREATE TABLE cookies(host_key TEXT, name TEXT)")
    connection.execute("INSERT INTO cookies VALUES('.chatgpt.com', 'fixture')")
    connection.commit()
    connection.close()
PY

bash "$repo_dir/scripts/migrate-electron-profile.sh" \
  --source "$source_profile" --target "$target_profile"
[[ -f $target_profile/Cookies && -f "$target_profile/Local Storage/leveldb/000001.ldb" ]]
[[ ! -e $target_profile/Partitions/codex-browser-app/Cache/cache-entry ]]
marker="$temporary/state/chatgpt-work-linux/electron-profile-migration.json"
[[ -s $marker ]]

# A successful migration is idempotent and must not overwrite newer isolated
# state during a later application update.
printf '%s\n' '{"profile":{"name":"newer-isolated"}}' >"$target_profile/Preferences"
bash "$repo_dir/scripts/migrate-electron-profile.sh" \
  --source "$source_profile" --target "$target_profile"
rg -q 'newer-isolated' "$target_profile/Preferences"

printf '%s\n' '{"old":true}' >"$target_profile/Preferences"
rm -f -- "$marker"
if bash "$repo_dir/scripts/migrate-electron-profile.sh" \
  --source "$source_profile" --target "$target_profile" >/dev/null 2>&1; then
  printf 'electron_profile_migration: replaced a target without explicit approval\n' >&2
  exit 1
fi
bash "$repo_dir/scripts/migrate-electron-profile.sh" \
  --source "$source_profile" --target "$target_profile" --replace-target
rg -q '"profile"' "$target_profile/Preferences"
backup=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["backup"])' "$marker")
[[ -f $backup/Preferences ]]
rg -q '"old"' "$backup/Preferences"

printf 'electron_profile_migration: passed\n'
