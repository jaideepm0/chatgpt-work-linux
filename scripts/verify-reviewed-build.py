#!/usr/bin/env python3
"""Verify that a generated build came from the exact reviewed DMG snapshot."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("build", type=Path)
    parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()

    with args.snapshot.open(encoding="utf-8") as handle:
        snapshot = json.load(handle)
    with (args.build / ".codex-linux/build-info.json").open(encoding="utf-8") as handle:
        build_info = json.load(handle)
    upstream = build_info["upstreamDmg"]

    expected_version = snapshot["application"]["short_version"]
    expected_artifact = snapshot["artifact"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", expected_version):
        raise SystemExit("reviewed snapshot has an invalid version")
    comparisons = {
        "artifact name": (upstream.get("fileName"), expected_artifact["name"]),
        "version": (upstream.get("appVersion"), expected_version),
        "SHA-256": (upstream.get("sha256"), expected_artifact["sha256"]),
        "size": (int(upstream.get("sizeBytes", -1)), int(expected_artifact["size"])),
    }
    for label, (actual, expected) in comparisons.items():
        if actual != expected:
            raise SystemExit(f"build {label} differs from reviewed snapshot")

    source = build_info.get("source")
    if not isinstance(source, dict):
        raise SystemExit("build source provenance is missing")
    if source.get("dirty") is not False:
        raise SystemExit("build source provenance is dirty or ambiguous")
    if not re.fullmatch(r"[0-9a-f]{40}", str(source.get("commit", ""))):
        raise SystemExit("build source commit is invalid")

    launcher = (args.build / "start.sh").read_text(encoding="utf-8")
    if f"CHATGPT_WORK_UPSTREAM_VERSION={expected_version}\n" not in launcher:
        raise SystemExit("launcher version differs from reviewed snapshot")
    subprocess.run(
        ["sha256sum", "--check", "--quiet", "--strict", ".codex-linux/SHA256SUMS"],
        cwd=args.build,
        check=True,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"verify-reviewed-build: {error}", file=sys.stderr)
        raise SystemExit(1)
