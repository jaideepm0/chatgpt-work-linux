#!/usr/bin/env python3
"""Merge threads from the former isolated Linux app home into CODEX_HOME."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


TABLES = ("threads", "thread_dynamic_tools", "thread_spawn_edges")
MAX_INDEX_BYTES = 64 * 1024 * 1024


def fail(message: str) -> None:
    raise SystemExit(f"migrate-codex-history: {message}")


def readonly_connection(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True, timeout=30)
    connection.row_factory = sqlite3.Row
    return connection


def check_integrity(connection: sqlite3.Connection, label: str) -> None:
    result = connection.execute("PRAGMA quick_check").fetchone()
    if result is None or result[0] != "ok":
        fail(f"{label} database failed quick_check: {result[0] if result else 'no result'}")


def table_signature(connection: sqlite3.Connection, table: str) -> list[tuple[Any, ...]]:
    return [tuple(row) for row in connection.execute(f"PRAGMA table_info({table})")]


def migration_signature(connection: sqlite3.Connection) -> list[tuple[Any, ...]]:
    try:
        return [
            tuple(row)
            for row in connection.execute(
                "SELECT version, checksum FROM _sqlx_migrations ORDER BY version"
            )
        ]
    except sqlite3.OperationalError as error:
        fail(f"database has no Codex migration metadata: {error}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def atomic_copy(source: Path, target: Path) -> bool:
    if target.exists():
        if target.is_file() and source.stat().st_size == target.stat().st_size:
            if sha256(source) == sha256(target):
                return False
        fail(f"refusing to overwrite a different session file: {target}")

    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(target.parent, 0o700)
    source_digest = sha256(source)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{target.name}.migration-", dir=target.parent
    )
    temporary = Path(temporary_name)
    try:
        with source.open("rb") as source_handle, os.fdopen(descriptor, "wb") as target_handle:
            shutil.copyfileobj(source_handle, target_handle, 1024 * 1024)
            target_handle.flush()
            os.fsync(target_handle.fileno())
        os.chmod(temporary, 0o600)
        if sha256(temporary) != source_digest:
            fail(f"copied session failed SHA-256 verification: {source}")
        os.replace(temporary, target)
        directory_fd = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)
    return True


def read_index(path: Path) -> tuple[list[str], dict[str, dict[str, Any]]]:
    if not path.exists():
        return [], {}
    if not path.is_file() or path.stat().st_size > MAX_INDEX_BYTES:
        fail(f"invalid or unreasonably large session index: {path}")

    order: list[str] = []
    records: dict[str, dict[str, Any]] = {}
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                fail(f"invalid JSON in {path}:{line_number}: {error}")
            identifier = record.get("id")
            if not isinstance(identifier, str) or not identifier:
                fail(f"session index record has no string id in {path}:{line_number}")
            if identifier not in records:
                order.append(identifier)
            records[identifier] = record
    return order, records


def merge_index(source: Path, target: Path, imported_ids: set[str]) -> int:
    target_order, target_records = read_index(target)
    source_order, source_records = read_index(source)
    imported = 0
    for identifier in source_order:
        if identifier not in imported_ids or identifier not in source_records:
            continue
        source_record = source_records[identifier]
        target_record = target_records.get(identifier)
        if target_record is None:
            target_order.append(identifier)
            target_records[identifier] = source_record
            imported += 1
        elif str(source_record.get("updated_at", "")) > str(
            target_record.get("updated_at", "")
        ):
            target_records[identifier] = source_record

    if imported == 0:
        return 0
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{target.name}.migration-", dir=target.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            for identifier in target_order:
                handle.write(
                    json.dumps(target_records[identifier], separators=(",", ":")) + "\n"
                )
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)
    return imported


def backup_database(connection: sqlite3.Connection, backup: Path) -> None:
    backup.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(backup.parent, 0o700)
    backup_connection = sqlite3.connect(backup)
    try:
        connection.backup(backup_connection)
    finally:
        backup_connection.close()
    os.chmod(backup, 0o600)


def prune_backups(directory: Path) -> None:
    backups = sorted(
        directory.glob("state_5.*.sqlite"), key=lambda path: path.stat().st_mtime, reverse=True
    )
    for stale in backups[3:]:
        stale.unlink()


def parse_arguments() -> argparse.Namespace:
    home = Path.home()
    xdg_data = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share"))
    parser = argparse.ArgumentParser(
        description="Recover Codex threads written to the former isolated Linux app home."
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=xdg_data / "chatgpt-work-linux/codex-home",
        help="former isolated Codex home",
    )
    parser.add_argument(
        "--target",
        type=Path,
        default=Path(os.environ.get("CODEX_HOME", home / ".codex")),
        help="canonical Codex home",
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_arguments()
    source = args.source.expanduser().resolve(strict=True)
    target = args.target.expanduser().resolve(strict=True)
    if source == target:
        fail("source and target resolve to the same directory")
    source_database = source / "state_5.sqlite"
    target_database = target / "state_5.sqlite"
    if not source_database.is_file() or not target_database.is_file():
        fail("both source and target must contain state_5.sqlite")

    state_home = Path(
        os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")
    ).expanduser()
    state_directory = state_home / "chatgpt-work-linux"
    state_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(state_directory, 0o700)
    lock_path = state_directory / "codex-history-migration.lock"
    with lock_path.open("a+", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail("another history migration is already running")

        source_connection = readonly_connection(source_database)
        target_connection = sqlite3.connect(target_database, timeout=30)
        target_connection.row_factory = sqlite3.Row
        try:
            target_connection.execute("PRAGMA busy_timeout=30000")
            target_connection.execute("PRAGMA foreign_keys=ON")
            check_integrity(source_connection, "source")
            check_integrity(target_connection, "target")
            for table in TABLES:
                if table_signature(source_connection, table) != table_signature(
                    target_connection, table
                ):
                    fail(f"source and target {table} schemas differ")
            if migration_signature(source_connection) != migration_signature(target_connection):
                fail("source and target Codex database migrations differ")

            target_ids = {
                row[0] for row in target_connection.execute("SELECT id FROM threads")
            }
            source_rows = list(source_connection.execute("SELECT * FROM threads"))
            imported_rows = [row for row in source_rows if row["id"] not in target_ids]
            imported_ids = {row["id"] for row in imported_rows}
            path_mapping: dict[str, str] = {}
            for row in imported_rows:
                rollout = Path(row["rollout_path"]).expanduser().resolve(strict=True)
                if not rollout.is_file() or not (
                    within(rollout, source / "sessions")
                    or within(rollout, source / "archived_sessions")
                ):
                    fail(f"thread {row['id']} has an unsafe rollout path: {rollout}")
                destination = target / rollout.relative_to(source)
                path_mapping[row["id"]] = str(destination)

            report = {
                "source": str(source),
                "target": str(target),
                "sourceThreads": len(source_rows),
                "targetThreadsBefore": len(target_ids),
                "threadsToImport": len(imported_rows),
                "dryRun": args.dry_run,
            }
            if args.dry_run or not imported_rows:
                report["status"] = "ready" if args.dry_run else "already-merged"
                print(json.dumps(report, sort_keys=True))
                return

            timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
            backup_directory = state_directory / "migration-backups"
            backup = backup_directory / f"state_5.{timestamp}.sqlite"
            backup_database(target_connection, backup)
            target_index = target / "session_index.jsonl"
            if target_index.is_file():
                shutil.copy2(target_index, backup.with_suffix(".session_index.jsonl"))
                os.chmod(backup.with_suffix(".session_index.jsonl"), 0o600)

            copied_files = 0
            for row in imported_rows:
                source_rollout = Path(row["rollout_path"]).expanduser().resolve(strict=True)
                if atomic_copy(source_rollout, Path(path_mapping[row["id"]])):
                    copied_files += 1
            shell_snapshots = source / "shell_snapshots"
            if shell_snapshots.is_dir():
                for snapshot in shell_snapshots.iterdir():
                    if snapshot.is_file() and any(
                        identifier in snapshot.name for identifier in imported_ids
                    ):
                        copied_files += int(
                            atomic_copy(snapshot, target / "shell_snapshots" / snapshot.name)
                        )

            index_records = merge_index(
                source / "session_index.jsonl", target_index, imported_ids
            )
            columns = [row[1] for row in table_signature(target_connection, "threads")]
            placeholders = ",".join("?" for _ in columns)
            rollout_index = columns.index("rollout_path")
            target_connection.execute("BEGIN IMMEDIATE")
            try:
                for row in imported_rows:
                    values = list(row)
                    values[rollout_index] = path_mapping[row["id"]]
                    target_connection.execute(
                        f"INSERT INTO threads VALUES ({placeholders})", values
                    )

                for row in source_connection.execute("SELECT * FROM thread_dynamic_tools"):
                    if row["thread_id"] in imported_ids:
                        values = list(row)
                        target_connection.execute(
                            f"INSERT OR IGNORE INTO thread_dynamic_tools VALUES "
                            f"({','.join('?' for _ in values)})",
                            values,
                        )

                all_ids = target_ids | imported_ids
                for row in source_connection.execute("SELECT * FROM thread_spawn_edges"):
                    if (
                        row["child_thread_id"] in imported_ids
                        and row["parent_thread_id"] in all_ids
                        and row["child_thread_id"] in all_ids
                    ):
                        values = list(row)
                        target_connection.execute(
                            f"INSERT OR IGNORE INTO thread_spawn_edges VALUES "
                            f"({','.join('?' for _ in values)})",
                            values,
                        )
                target_connection.commit()
            except BaseException:
                target_connection.rollback()
                raise

            check_integrity(target_connection, "merged target")
            final_count = target_connection.execute("SELECT count(*) FROM threads").fetchone()[0]
            expected_count = len(target_ids) + len(imported_ids)
            if final_count != expected_count:
                fail(f"merged thread count is {final_count}, expected {expected_count}")
            prune_backups(backup_directory)
            report.update(
                {
                    "status": "merged",
                    "threadsImported": len(imported_ids),
                    "targetThreadsAfter": final_count,
                    "filesCopied": copied_files,
                    "indexRecordsImported": index_records,
                    "backup": str(backup),
                }
            )
            print(json.dumps(report, sort_keys=True))
        finally:
            source_connection.close()
            target_connection.close()


if __name__ == "__main__":
    try:
        main()
    except (OSError, sqlite3.Error) as error:
        print(f"migrate-codex-history: {error}", file=sys.stderr)
        raise SystemExit(1) from error
