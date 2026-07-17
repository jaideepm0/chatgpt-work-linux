#!/usr/bin/env python3
"""Require the Linux capability patches that define this Work build."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


REQUIRED_PATCHES = {
    "linux-explicit-tray-quit",
    "linux-launch-actions",
    "linux-settings-persistence",
    "linux-single-instance",
    "linux-tray",
    "linux-computer-use-ui-feature",
    "linux-computer-use-plugin-gate",
    "linux-computer-use-native-desktop-apps",
    "linux-computer-use-ui-availability",
    "linux-computer-use-install-flow",
}
ACCEPTED_STATUSES = {"applied", "already-applied"}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    args = parser.parse_args()

    try:
        report = json.loads(args.report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"validate-work-patch-report: invalid report: {error}") from error

    patches = report.get("patches")
    if not isinstance(patches, list):
        raise SystemExit("validate-work-patch-report: report has no patches array")

    enabled_features = report.get("enabledFeatures")
    if enabled_features != []:
        raise SystemExit(
            "validate-work-patch-report: optional Linux features must remain disabled"
        )

    selected: dict[str, list[str]] = {name: [] for name in REQUIRED_PATCHES}
    for patch in patches:
        if not isinstance(patch, dict):
            continue
        name = patch.get("name")
        if name in selected:
            selected[name].append(str(patch.get("status")))

    failures = []
    for name, statuses in sorted(selected.items()):
        if len(statuses) != 1:
            failures.append(f"{name}: expected once, found {len(statuses)}")
        elif statuses[0] not in ACCEPTED_STATUSES:
            failures.append(f"{name}: {statuses[0]}")

    if failures:
        raise SystemExit(
            "validate-work-patch-report: required Work capability patches failed:\n  - "
            + "\n  - ".join(failures)
        )

    print(
        "Required Linux tray, warm-start, single-instance, and Computer Use "
        "patches passed; optional features are disabled."
    )


if __name__ == "__main__":
    main()
