#!/usr/bin/env python3
"""Apply small same-size Work runtime fixes directly to a generated ASAR."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("asar", type=Path)
    args = parser.parse_args()

    prewarm_anchor = b"process.platform===`linux`&&codexLinuxPrewarmHotkeyWindow()"
    payload = args.asar.read_bytes()
    count = payload.count(prewarm_anchor)
    if count != 1:
        raise SystemExit(f"patch-work-asar: expected one startup prewarm call, found {count}")

    # Keep the ASAR byte layout unchanged: replacing with a same-width no-op
    # avoids changing archive offsets while retaining Quick Chat on demand.
    prewarm_replacement = b"void 0" + (b" " * (len(prewarm_anchor) - len(b"void 0")))
    patched = payload.replace(prewarm_anchor, prewarm_replacement, 1)

    # The unified renderer's Computer Use hook still carries an upstream
    # macOS/Windows-only predicate. The adapter patches settings discovery, but
    # this shared predicate is the final source of "Unavailable in this
    # context" on Linux. This Linux artifact does not execute on macOS, so
    # exchange the macOS branch for Linux while retaining Windows and preserving
    # every byte offset in the ASAR.
    predicate = re.compile(
        rb"function ([A-Za-z_$][A-Za-z0-9_$]*)\(([A-Za-z_$][A-Za-z0-9_$]*)\)"
        rb"\{return \2===`macOS`\|\|\2===`windows`\}"
    )
    matches = list(predicate.finditer(patched))
    if len(matches) != 1:
        raise SystemExit(
            "patch-work-asar: expected one Computer Use platform predicate, "
            f"found {len(matches)}"
        )
    original = matches[0].group(0)
    replacement = original.replace(b"`macOS`", b"`linux`", 1)
    if len(replacement) != len(original):
        raise SystemExit("patch-work-asar: Computer Use replacement changed byte length")
    patched = patched[: matches[0].start()] + replacement + patched[matches[0].end() :]

    if b"===`linux`||" not in replacement:
        raise SystemExit("patch-work-asar: Computer Use Linux predicate was not produced")

    # The same hook receives rollout and feature booleans which are not
    # provisioned for the community Linux build. Keep the user's enabled flag,
    # platform loading state, Electron-window check, and platform predicate,
    # but make the three Linux build-time gates deterministic. Replacing the
    # minified identifier values with same-width numeric booleans again keeps
    # the archive layout unchanged.
    availability_call = re.compile(
        rb"([A-Za-z_$][A-Za-z0-9_$]*)=([A-Za-z_$][A-Za-z0-9_$]*)\(\{"
        rb"areRequiredFeaturesEnabled:([A-Za-z_$][A-Za-z0-9_$]*),"
        rb"enabled:([A-Za-z_$][A-Za-z0-9_$]*),"
        rb"isAnyFeatureLoading:([A-Za-z_$][A-Za-z0-9_$]*),"
        rb"isComputerUseGateEnabled:([A-Za-z_$][A-Za-z0-9_$]*),"
        rb"isHostCompatiblePlatform:([A-Za-z_$][A-Za-z0-9_$]*)\("
        rb"([A-Za-z_$][A-Za-z0-9_$]*)\),"
        rb"isPlatformLoading:([A-Za-z_$][A-Za-z0-9_$]*),windowType:`electron`\}\)"
    )
    calls = list(availability_call.finditer(patched))
    computer_use_calls = [
        match
        for match in calls
        if b"featureName:`computer_use`"
        in patched[max(0, match.start() - 1600) : match.start()]
    ]
    if len(computer_use_calls) != 1:
        raise SystemExit(
            "patch-work-asar: expected one Computer Use availability call, "
            f"found {len(computer_use_calls)}"
        )
    call_match = computer_use_calls[0]
    call = bytearray(call_match.group(0))
    for group_index, boolean in ((3, b"1"), (5, b"0"), (6, b"1")):
        start, end = call_match.span(group_index)
        relative_start = start - call_match.start()
        relative_end = end - call_match.start()
        call[relative_start:relative_end] = boolean + (b" " * (relative_end - relative_start - 1))
    patched = (
        patched[: call_match.start()]
        + bytes(call)
        + patched[call_match.end() :]
    )
    if len(patched) != len(payload):
        raise SystemExit("patch-work-asar: final patch changed ASAR byte length")

    temporary = args.asar.with_name(f".{args.asar.name}.new-{os.getpid()}")
    temporary.write_bytes(patched)
    os.chmod(temporary, args.asar.stat().st_mode)
    os.replace(temporary, args.asar)


if __name__ == "__main__":
    main()
