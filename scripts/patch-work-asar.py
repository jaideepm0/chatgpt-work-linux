#!/usr/bin/env python3
"""Apply small same-size Work runtime fixes directly to a generated ASAR."""

from __future__ import annotations

import argparse
import os
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("asar", type=Path)
    args = parser.parse_args()

    anchor = b"process.platform===`linux`&&codexLinuxPrewarmHotkeyWindow()"
    payload = args.asar.read_bytes()
    count = payload.count(anchor)
    if count != 1:
        raise SystemExit(f"patch-work-asar: expected one startup prewarm call, found {count}")

    # Keep the ASAR byte layout unchanged: replacing with a same-width no-op
    # avoids changing archive offsets while retaining Quick Chat on demand.
    replacement = b"void 0" + (b" " * (len(anchor) - len(b"void 0")))
    patched = payload.replace(anchor, replacement, 1)
    temporary = args.asar.with_name(f".{args.asar.name}.new-{os.getpid()}")
    temporary.write_bytes(patched)
    os.chmod(temporary, args.asar.stat().st_mode)
    os.replace(temporary, args.asar)


if __name__ == "__main__":
    main()
