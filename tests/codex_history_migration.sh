#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d -t chatgpt-work-history-test.XXXXXX)
cleanup() {
  rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

source_home="$temporary/source"
target_home="$temporary/target"
state_home="$temporary/state"
mkdir -p -- "$source_home/sessions/2026/07/17" "$target_home/sessions/2026/07/16"

python3 - "$source_home" "$target_home" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
schema = """
CREATE TABLE _sqlx_migrations(version INTEGER PRIMARY KEY, checksum BLOB NOT NULL);
INSERT INTO _sqlx_migrations VALUES(1, X'0102');
CREATE TABLE threads(
  id TEXT PRIMARY KEY,
  rollout_path TEXT NOT NULL,
  title TEXT NOT NULL,
  updated_at_ms INTEGER NOT NULL
);
CREATE TABLE thread_dynamic_tools(
  thread_id TEXT NOT NULL,
  position INTEGER NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY(thread_id, position)
);
CREATE TABLE thread_spawn_edges(
  parent_thread_id TEXT NOT NULL,
  child_thread_id TEXT NOT NULL PRIMARY KEY,
  status TEXT NOT NULL
);
"""
source_rollout = source / "sessions/2026/07/17/rollout-source-thread.jsonl"
target_rollout = target / "sessions/2026/07/16/rollout-target-thread.jsonl"
source_rollout.write_text('{"type":"session_meta","id":"source-thread"}\n', encoding="utf-8")
target_rollout.write_text('{"type":"session_meta","id":"target-thread"}\n', encoding="utf-8")
for home, identifier, rollout, title, updated in (
    (source, "source-thread", source_rollout, "Recovered thread", 2000),
    (target, "target-thread", target_rollout, "Existing thread", 1000),
):
    connection = sqlite3.connect(home / "state_5.sqlite")
    connection.executescript(schema)
    connection.execute(
        "INSERT INTO threads VALUES(?,?,?,?)",
        (identifier, str(rollout), title, updated),
    )
    if identifier == "source-thread":
        connection.execute(
            "INSERT INTO thread_dynamic_tools VALUES(?,?,?)",
            (identifier, 0, "fixture"),
        )
    connection.commit()
    connection.close()
    (home / "session_index.jsonl").write_text(
        json.dumps(
            {
                "id": identifier,
                "thread_name": title,
                "updated_at": f"2026-07-{17 if identifier == 'source-thread' else 16}T00:00:00Z",
            },
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )
PY

dry_run=$(XDG_STATE_HOME="$state_home" python3 "$repo_root/scripts/migrate-codex-history.py" \
  --source "$source_home" --target "$target_home" --dry-run)
python3 -c 'import json,sys; report=json.load(sys.stdin); assert report["threadsToImport"] == 1 and report["status"] == "ready"' <<<"$dry_run"
[[ $(sqlite3 -readonly "$target_home/state_5.sqlite" 'select count(*) from threads') == 1 ]]

report=$(XDG_STATE_HOME="$state_home" python3 "$repo_root/scripts/migrate-codex-history.py" \
  --source "$source_home" --target "$target_home")
python3 -c 'import json,sys; report=json.load(sys.stdin); assert report["threadsImported"] == 1 and report["targetThreadsAfter"] == 2' <<<"$report"
[[ $(sqlite3 -readonly "$target_home/state_5.sqlite" 'pragma quick_check') == ok ]]
[[ $(sqlite3 -readonly "$target_home/state_5.sqlite" 'select count(*) from threads') == 2 ]]
[[ $(sqlite3 -readonly "$target_home/state_5.sqlite" 'select count(*) from thread_dynamic_tools') == 1 ]]
rollout=$(sqlite3 -readonly "$target_home/state_5.sqlite" "select rollout_path from threads where id='source-thread'")
[[ $rollout == "$target_home/sessions/2026/07/17/rollout-source-thread.jsonl" && -f $rollout ]]
[[ $(wc -l <"$target_home/session_index.jsonl") == 2 ]]
[[ $(find "$state_home/chatgpt-work-linux/migration-backups" -name 'state_5.*.sqlite' | wc -l) == 1 ]]

second=$(XDG_STATE_HOME="$state_home" python3 "$repo_root/scripts/migrate-codex-history.py" \
  --source "$source_home" --target "$target_home")
python3 -c 'import json,sys; report=json.load(sys.stdin); assert report["status"] == "already-merged" and report["threadsToImport"] == 0' <<<"$second"

printf 'codex_history_migration: passed\n'
