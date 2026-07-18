#!/usr/bin/env python3
"""Apply small same-size Work runtime fixes directly to a generated ASAR."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re


def replace_same_size(payload: bytes, old: bytes, new: bytes, label: str) -> bytes:
    count = payload.count(old)
    if count != 1:
        raise SystemExit(f"patch-work-asar: expected one {label}, found {count}")
    if len(new) > len(old):
        raise SystemExit(f"patch-work-asar: {label} replacement is too large")
    return payload.replace(old, new + (b" " * (len(old) - len(new))), 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("asar", type=Path)
    args = parser.parse_args()

    prewarm_anchor = b"process.platform===`linux`&&codexLinuxPrewarmHotkeyWindow()"
    payload = args.asar.read_bytes()
    # Keep the ASAR byte layout unchanged: replacing with a same-width no-op
    # avoids changing archive offsets while retaining Quick Chat on demand.
    patched = replace_same_size(payload, prewarm_anchor, b"void 0", "startup prewarm call")

    # Lifecycle features must be opt-in.  The adapter's original `!== false`
    # default silently enables every missing Linux setting, which makes a
    # freshly created profile retain the full Electron/app-server tree after
    # the last window closes.  `=== true` is the same byte length, preserves
    # explicit user choices, and keeps the ASAR layout stable.
    patched = replace_same_size(
        patched,
        b"codexLinuxGetSetting=e=>process.platform!==`linux`||P.globalState.get(e)!==!1",
        b"codexLinuxGetSetting=e=>process.platform!==`linux`||P.globalState.get(e)===!0",
        "Linux lifecycle setting default",
    )

    # The current upstream creates a tray on Linux unconditionally, leaving the
    # reviewed Linux setting disconnected. Route the existing startup branch
    # through the adapter's setting helper. The replacement remains
    # exactly the same size so ASAR offsets are unchanged.
    tray_start_anchor = b"(A||process.platform===`linux`)&&Ce()"
    tray_start_replacement = b"(A||codexLinuxIsTrayEnabled())&&Ce() "
    patched = replace_same_size(
        patched, tray_start_anchor, tray_start_replacement, "Linux tray startup branch"
    )

    # The official runtime extends Tray with whenReady()/isReady(). Stock
    # Electron implements the portable Tray API without those private methods.
    # Its constructor is synchronous, so absence of the extensions is the
    # successful fallback; treating it as failure immediately destroys the
    # standard Linux tray and also disables close-to-tray.
    patched = replace_same_size(
        patched,
        b"if(typeof t.whenReady!=`function`)return process.platform!==`linux`;",
        b"if(typeof t.whenReady!=`function`)return!0;",
        "portable Electron tray readiness fallback",
    )
    patched = replace_same_size(
        patched,
        b"return typeof t.isReady==`function`?t.isReady():process.platform!==`linux`",
        b"return typeof t.isReady==`function`?t.isReady():!0",
        "portable Electron tray state fallback",
    )

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
