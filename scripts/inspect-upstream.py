#!/usr/bin/env python3
"""Inspect the official ChatGPT macOS artifact without executing its contents.

The inspector intentionally uses only Python's standard library plus a recent
7-Zip executable. 7-Zip handles the DMG/HFS container; plist and Mach-O parsing
is performed locally from a small, explicitly selected set of archive members.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from typing import Any, Iterable
from urllib.parse import urlsplit


OFFICIAL_URL = "https://persistent.oaistatic.com/sidekick/public/ChatGPT.dmg"
ALLOWED_UPSTREAM_URLS = frozenset({OFFICIAL_URL})
MAX_PLIST_BYTES = 2 * 1024 * 1024
MAX_BINARY_BYTES = 512 * 1024 * 1024
MAX_SELECTED_BINARY_BYTES = 1024 * 1024 * 1024
MAX_SELECTED_BINARIES = 64

# These are exact resource-bundle names, not claims that an account is entitled
# to a feature or that the feature can be rehosted on Linux. Recording them lets
# maintainers detect meaningful upstream product drift without extracting or
# interpreting proprietary UI resources.
FEATURE_BUNDLE_MARKERS = {
    "ChatGPTADAVisualization_ChatGPTADAVisualization.bundle": "data_visualization",
    "ChatGPTAutomation_ChatGPTAutomation.bundle": "automations",
    "ChatGPTCodeExecution_ChatGPTCodeExecution.bundle": "code_execution",
    "ChatGPTConnectors_ChatGPTConnectors.bundle": "connectors",
    "ChatGPTDesktopCommon_ChatGPTDesktopCommon.bundle": "desktop_integration",
    "ChatGPTFileLibrary_ChatGPTFileLibrary.bundle": "file_library",
    "ChatGPTPresentation_ChatGPTPresentation.bundle": "presentations",
    "ChatGPTProjectConnectors_ChatGPTProjectConnectors.bundle": "project_connectors",
    "ChatGPTReviewAction_ChatGPTReviewAction.bundle": "action_review",
    "ChatGPTSites_ChatGPTSites.bundle": "sites",
    "ChatGPTTextEditor_ChatGPTTextEditor.bundle": "text_editor",
    "ChatGPTWritingBlocks_ChatGPTWritingBlocks.bundle": "writing_blocks",
    "Hive_Meeting.bundle": "meetings",
}


class InspectionError(RuntimeError):
    """An expected validation or inspection step failed."""


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Safely inspect an official ChatGPT DMG and emit deterministic JSON."
    )
    parser.add_argument(
        "--dmg", required=True, type=Path, help="existing DMG to inspect"
    )
    parser.add_argument(
        "--source-url",
        default=OFFICIAL_URL,
        help="provenance URL; must match the compiled allowlist",
    )
    parser.add_argument(
        "--headers",
        type=Path,
        help="optional raw HTTP response headers captured by fetch-upstream.sh",
    )
    parser.add_argument(
        "--header",
        action="append",
        default=[],
        metavar="NAME:VALUE",
        help="additional stable HTTP header metadata (repeatable)",
    )
    parser.add_argument(
        "--artifact-name",
        default=None,
        help="stable display name; defaults to the DMG basename",
    )
    parser.add_argument(
        "--seven-zip",
        default=os.environ.get("CHATGPT_WORK_7Z", "7z"),
        help="7-Zip executable (default: CHATGPT_WORK_7Z or 7z)",
    )
    return parser.parse_args(argv)


def validate_source_url(value: str) -> str:
    parsed = urlsplit(value)
    if parsed.scheme != "https":
        raise InspectionError("upstream source URL must use HTTPS")
    if parsed.username or parsed.password or parsed.fragment:
        raise InspectionError("upstream source URL contains forbidden components")
    if value not in ALLOWED_UPSTREAM_URLS:
        raise InspectionError(f"upstream source URL is not allowlisted: {value}")
    return value


def resolve_executable(value: str) -> str:
    resolved = shutil.which(value)
    if not resolved:
        raise InspectionError(f"7-Zip executable not found: {value}")
    return resolved


def hash_file(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            size += len(chunk)
            digest.update(chunk)
    return size, digest.hexdigest()


def run_7z(
    executable: str,
    args: list[str],
    *,
    timeout: int,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    try:
        result = subprocess.run(
            [executable, *args],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired as exc:
        raise InspectionError(
            f"7-Zip timed out while running: {' '.join(args[:2])}"
        ) from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()[-1200:]
        raise InspectionError(f"7-Zip failed ({result.returncode}): {detail}")
    return result


def extract_member(
    executable: str,
    dmg: Path,
    archive_path: str,
    destination: Path,
    *,
    expected_max_size: int,
) -> None:
    ensure_safe_archive_path(archive_path)
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    try:
        with destination.open("wb") as output:
            result = subprocess.run(
                [executable, "e", "-so", "-bd", "-y", str(dmg), archive_path],
                check=False,
                stdout=output,
                stderr=subprocess.PIPE,
                timeout=600,
                env=env,
            )
    except subprocess.TimeoutExpired as exc:
        destination.unlink(missing_ok=True)
        raise InspectionError(f"7-Zip timed out extracting {archive_path}") from exc
    if result.returncode != 0:
        destination.unlink(missing_ok=True)
        detail = result.stderr.decode("utf-8", "replace").strip()[-1200:]
        raise InspectionError(f"7-Zip could not extract {archive_path}: {detail}")
    actual_size = destination.stat().st_size
    if actual_size > expected_max_size:
        destination.unlink(missing_ok=True)
        raise InspectionError(
            f"extracted member exceeds safety limit ({actual_size} bytes): {archive_path}"
        )


def ensure_safe_archive_path(value: str) -> None:
    if (
        not value
        or value[0] in {"-", "@"}
        or "\x00" in value
        or "\\" in value
        or any(character in value for character in "*?[]")
    ):
        raise InspectionError(f"unsafe archive path: {value!r}")
    parsed = PurePosixPath(value)
    if parsed.is_absolute() or any(part in {"", ".", ".."} for part in parsed.parts):
        raise InspectionError(f"unsafe archive path: {value!r}")


def parse_slt_entries(output: str) -> list[dict[str, str]]:
    if not re.search(r"(?m)^Type = Dmg\r?$", output):
        raise InspectionError("7-Zip did not identify the input as an Apple DMG")
    marker = "----------"
    if marker not in output:
        raise InspectionError("7-Zip technical listing did not contain archive entries")
    entry_text = output.split(marker, 1)[1]
    entries: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for raw_line in entry_text.splitlines():
        line = raw_line.rstrip("\r")
        if not line:
            if "Path" in current:
                entries.append(current)
            current = {}
            continue
        key, separator, value = line.partition(" = ")
        if separator:
            current[key] = value
    if "Path" in current:
        entries.append(current)
    if not entries:
        raise InspectionError("DMG contains no inspectable archive entries")
    return entries


def entry_size(entry: dict[str, str]) -> int | None:
    raw = entry.get("Size", "")
    if not raw:
        return None
    try:
        value = int(raw)
    except ValueError as exc:
        raise InspectionError(
            f"invalid archive member size for {entry.get('Path')}: {raw}"
        ) from exc
    if value < 0:
        raise InspectionError(f"negative archive member size for {entry.get('Path')}")
    return value


def parse_http_headers(raw: str) -> dict[str, str]:
    blocks: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for raw_line in raw.splitlines():
        line = raw_line.rstrip("\r")
        if line.upper().startswith("HTTP/"):
            current = {":status": line}
            blocks.append(current)
            continue
        if not line or current is None or ":" not in line:
            continue
        name, value = line.split(":", 1)
        current[name.strip().lower()] = value.strip()
    return blocks[-1] if blocks else {}


def stable_http_metadata(headers: dict[str, str]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    mappings = {
        "accept-ranges": "accept_ranges",
        "content-type": "content_type",
        "etag": "etag",
        "last-modified": "last_modified",
    }
    for source_name, output_name in mappings.items():
        if value := headers.get(source_name):
            result[output_name] = value
    if value := headers.get("content-length"):
        try:
            result["content_length"] = int(value)
        except ValueError as exc:
            raise InspectionError(f"invalid Content-Length header: {value}") from exc
    return result


def collect_headers(path: Path | None, inline: Iterable[str]) -> dict[str, str]:
    headers: dict[str, str] = {}
    if path is not None:
        try:
            headers.update(
                parse_http_headers(path.read_text(encoding="utf-8", errors="replace"))
            )
        except OSError as exc:
            raise InspectionError(f"could not read header file {path}: {exc}") from exc
    for item in inline:
        name, separator, value = item.partition(":")
        if not separator or not name.strip():
            raise InspectionError(f"invalid --header value: {item!r}")
        headers[name.strip().lower()] = value.strip()
    return headers


CPU_TYPES = {
    7: "i386",
    12: "arm",
    0x01000007: "x86_64",
    0x0100000C: "arm64",
    0x0200000C: "arm64_32",
}
MACH_FILE_TYPES = {
    1: "object",
    2: "executable",
    3: "fixed-vm-library",
    4: "core",
    5: "preload",
    6: "dynamic-library",
    7: "dynamic-linker",
    8: "bundle",
    9: "dynamic-library-stub",
    10: "debug-symbols",
    11: "kernel-extension",
    12: "fileset",
}


def architecture_name(cpu_type: int) -> str:
    return CPU_TYPES.get(cpu_type, f"unknown-0x{cpu_type:08x}")


def parse_macho(path: Path) -> dict[str, Any] | None:
    with path.open("rb") as handle:
        header = handle.read(4096)
    if len(header) < 8:
        return None

    thin_magics = {
        b"\xfe\xed\xfa\xce": (">", 32),
        b"\xce\xfa\xed\xfe": ("<", 32),
        b"\xfe\xed\xfa\xcf": (">", 64),
        b"\xcf\xfa\xed\xfe": ("<", 64),
    }
    if header[:4] in thin_magics:
        endian, bits = thin_magics[header[:4]]
        if len(header) < (32 if bits == 64 else 28):
            raise InspectionError(f"truncated Mach-O header in {path.name}")
        cpu_type = struct.unpack_from(f"{endian}I", header, 4)[0]
        file_type = struct.unpack_from(f"{endian}I", header, 12)[0]
        return {
            "architectures": [architecture_name(cpu_type)],
            "bits": bits,
            "kind": MACH_FILE_TYPES.get(file_type, f"unknown-{file_type}"),
        }

    fat_magics = {
        b"\xca\xfe\xba\xbe": (">", 20),
        b"\xbe\xba\xfe\xca": ("<", 20),
        b"\xca\xfe\xba\xbf": (">", 32),
        b"\xbf\xba\xfe\xca": ("<", 32),
    }
    if header[:4] in fat_magics:
        endian, record_size = fat_magics[header[:4]]
        count = struct.unpack_from(f"{endian}I", header, 4)[0]
        if count == 0 or count > 64 or 8 + count * record_size > len(header):
            raise InspectionError(f"invalid universal Mach-O header in {path.name}")
        architectures = []
        for index in range(count):
            cpu_type = struct.unpack_from(
                f"{endian}I", header, 8 + index * record_size
            )[0]
            architectures.append(architecture_name(cpu_type))
        return {
            "architectures": sorted(set(architectures)),
            "bits": "universal",
            "kind": "universal-binary",
        }
    return None


def plist_string(plist: dict[str, Any], key: str) -> str | None:
    value = plist.get(key)
    return value if isinstance(value, str) and value else None


def url_schemes(plist: dict[str, Any]) -> list[str]:
    schemes: set[str] = set()
    values = plist.get("CFBundleURLTypes", [])
    if not isinstance(values, list):
        return []
    for item in values:
        if not isinstance(item, dict):
            continue
        candidates = item.get("CFBundleURLSchemes", [])
        if isinstance(candidates, list):
            schemes.update(
                value for value in candidates if isinstance(value, str) and value
            )
    return sorted(schemes)


def relevant_binary_paths(
    app_root: str,
    entries: list[dict[str, str]],
) -> list[tuple[str, int]]:
    prefix = f"{app_root}/"
    selected: list[tuple[str, int]] = []
    total_size = 0
    framework_pattern = re.compile(
        r"^Contents/Frameworks/(.+)\.framework/Versions/[^/]+/([^/]+)$"
    )
    for entry in entries:
        path = entry.get("Path", "")
        if not path.startswith(prefix) or entry.get("Folder") == "+":
            continue
        relative = path[len(prefix) :]
        framework_match = framework_pattern.match(relative)
        is_framework_binary = bool(
            framework_match and framework_match.group(1) == framework_match.group(2)
        )
        selected_path = (
            "/Contents/MacOS/" in f"/{relative}"
            or relative == "Contents/Resources/ChatGPTHelper"
            or is_framework_binary
            or (
                relative.startswith("Contents/Frameworks/")
                and relative.endswith(".dylib")
            )
        )
        if not selected_path:
            continue
        ensure_safe_archive_path(path)
        size = entry_size(entry)
        if size is None:
            continue
        if size > MAX_BINARY_BYTES:
            raise InspectionError(f"selected binary exceeds safety limit: {path}")
        total_size += size
        if total_size > MAX_SELECTED_BINARY_BYTES:
            raise InspectionError(
                "selected binaries exceed aggregate extraction safety limit"
            )
        selected.append((path, size))
    selected.sort()
    if len(selected) > MAX_SELECTED_BINARIES:
        raise InspectionError("too many candidate binaries in DMG")
    return selected


def classify_implementation(
    archive_paths: list[str], binaries: list[dict[str, Any]]
) -> tuple[str, list[str], list[str]]:
    lower_paths = [path.lower() for path in archive_paths]
    electron_markers: set[str] = set()
    if any(path.endswith("/app.asar") for path in lower_paths):
        electron_markers.add("app.asar")
    if any("electron framework.framework" in path for path in lower_paths):
        electron_markers.add("Electron Framework.framework")
    if any(path.endswith("/electron.asar") for path in lower_paths):
        electron_markers.add("electron.asar")

    native_markers: set[str] = set()
    if binaries:
        native_markers.add("Mach-O")
    if any("/libswift" in path for path in lower_paths):
        native_markers.add("Swift runtime")
    if any("/chatgpt.framework/" in path for path in lower_paths):
        native_markers.add("ChatGPT.framework")

    if electron_markers:
        implementation = "electron"
    elif binaries:
        implementation = "native-macos"
    else:
        implementation = "unknown"
    return implementation, sorted(electron_markers), sorted(native_markers)


def observed_feature_modules(app_root: str, archive_paths: list[str]) -> list[dict[str, str]]:
    prefix = f"{app_root}/Contents/Frameworks/ChatGPT.framework/Versions/A/Resources/"
    observed: list[dict[str, str]] = []
    for bundle, capability in FEATURE_BUNDLE_MARKERS.items():
        bundle_prefix = f"{prefix}{bundle}"
        if any(path == bundle_prefix or path.startswith(f"{bundle_prefix}/") for path in archive_paths):
            observed.append({"bundle": bundle, "capability": capability})
    return observed


def inspect(args: argparse.Namespace) -> dict[str, Any]:
    source_url = validate_source_url(args.source_url)
    dmg = args.dmg.expanduser().resolve()
    if not dmg.is_file():
        raise InspectionError(f"DMG does not exist or is not a regular file: {dmg}")
    artifact_name = args.artifact_name or dmg.name
    if not artifact_name or "/" in artifact_name or "\\" in artifact_name:
        raise InspectionError("artifact name must be a plain filename")

    seven_zip = resolve_executable(args.seven_zip)
    size, sha256 = hash_file(dmg)
    headers = stable_http_metadata(collect_headers(args.headers, args.header))
    expected_size = headers.get("content_length")
    if expected_size is not None and expected_size != size:
        raise InspectionError(
            f"Content-Length mismatch: headers={expected_size}, artifact={size}"
        )

    run_7z(seven_zip, ["t", "-bd", "-y", str(dmg)], timeout=600)
    listing = run_7z(seven_zip, ["l", "-slt", "-bd", str(dmg)], timeout=120)
    entries = parse_slt_entries(listing.stdout)
    paths = [entry["Path"] for entry in entries if entry.get("Path")]
    all_plist_candidates = sorted(
        path for path in paths if path.endswith(".app/Contents/Info.plist")
    )
    # Updater frameworks can contain nested helper applications. The product
    # app is the shallowest bundle in the mounted image.
    shallowest_depth = min(
        (len(PurePosixPath(path).parts) for path in all_plist_candidates),
        default=-1,
    )
    plist_candidates = [
        path
        for path in all_plist_candidates
        if len(PurePosixPath(path).parts) == shallowest_depth
    ]
    if len(plist_candidates) != 1:
        raise InspectionError(
            f"expected exactly one application Info.plist, found {len(plist_candidates)}"
        )
    plist_archive_path = plist_candidates[0]
    ensure_safe_archive_path(plist_archive_path)
    app_root = plist_archive_path[: -len("/Contents/Info.plist")]
    sizes_by_path = {entry.get("Path", ""): entry_size(entry) for entry in entries}
    declared_plist_size = sizes_by_path.get(plist_archive_path)
    if declared_plist_size is not None and declared_plist_size > MAX_PLIST_BYTES:
        raise InspectionError("application Info.plist exceeds safety limit")

    with tempfile.TemporaryDirectory(prefix="chatgpt-work-inspect-") as temporary:
        temporary_root = Path(temporary)
        plist_path = temporary_root / "Info.plist"
        extract_member(
            seven_zip,
            dmg,
            plist_archive_path,
            plist_path,
            expected_max_size=MAX_PLIST_BYTES,
        )
        if (
            declared_plist_size is not None
            and plist_path.stat().st_size != declared_plist_size
        ):
            raise InspectionError(
                "application Info.plist size differs from the archive listing"
            )
        try:
            plist = plistlib.loads(plist_path.read_bytes())
        except (OSError, plistlib.InvalidFileException, ValueError) as exc:
            raise InspectionError(
                f"could not parse application Info.plist: {exc}"
            ) from exc
        if not isinstance(plist, dict):
            raise InspectionError("application Info.plist is not a dictionary")

        binaries: list[dict[str, Any]] = []
        for index, (archive_path, declared_size) in enumerate(
            relevant_binary_paths(app_root, entries)
        ):
            extracted_path = temporary_root / f"binary-{index:02d}"
            extract_member(
                seven_zip,
                dmg,
                archive_path,
                extracted_path,
                expected_max_size=min(MAX_BINARY_BYTES, declared_size),
            )
            if extracted_path.stat().st_size != declared_size:
                raise InspectionError(
                    f"binary size differs from the archive listing: {archive_path}"
                )
            parsed = parse_macho(extracted_path)
            if parsed is None:
                continue
            relative_path = archive_path[len(app_root) + 1 :]
            binaries.append(
                {
                    "architectures": parsed["architectures"],
                    "bits": parsed["bits"],
                    "kind": parsed["kind"],
                    "path": relative_path,
                    "size": extracted_path.stat().st_size,
                }
            )

    binaries.sort(key=lambda value: value["path"])
    all_binary_architectures = sorted(
        {
            architecture
            for binary in binaries
            for architecture in binary["architectures"]
        }
    )
    implementation, electron_markers, native_markers = classify_implementation(
        paths, binaries
    )
    supported_platforms = plist.get("CFBundleSupportedPlatforms", [])
    if not isinstance(supported_platforms, list):
        supported_platforms = []
    supported_platforms = sorted(
        value for value in supported_platforms if isinstance(value, str)
    )

    executable_name = plist_string(plist, "CFBundleExecutable")
    main_executable = f"Contents/MacOS/{executable_name}" if executable_name else None
    main_binary = next(
        (binary for binary in binaries if binary["path"] == main_executable),
        None,
    )
    primary_architectures = (
        main_binary["architectures"] if main_binary else all_binary_architectures
    )

    application = {
        "all_binary_architectures": all_binary_architectures,
        "app_archive_path": app_root,
        "architectures": primary_architectures,
        "build_timestamp": plist_string(plist, "OAIBuildTimestamp"),
        "bundle_identifier": plist_string(plist, "CFBundleIdentifier"),
        "bundle_version": plist_string(plist, "CFBundleVersion"),
        "commit_hash": plist_string(plist, "OAICommitHash"),
        "display_name": plist_string(plist, "CFBundleDisplayName"),
        "electron_markers": electron_markers,
        "implementation": implementation,
        "main_executable": main_executable,
        "minimum_system_version": plist_string(plist, "LSMinimumSystemVersion"),
        "native_markers": native_markers,
        "observed_feature_modules": observed_feature_modules(app_root, paths),
        "short_version": plist_string(plist, "CFBundleShortVersionString"),
        "sparkle_public_key": plist_string(plist, "SUPublicEDKey"),
        "supported_platforms": supported_platforms,
        "url_schemes": url_schemes(plist),
    }

    return {
        "application": application,
        "artifact": {
            "archive_format": "dmg",
            "entry_count": len(entries),
            "name": artifact_name,
            "sha256": sha256,
            "size": size,
        },
        "binaries": binaries,
        "schema_version": 2,
        "source": {"http": headers, "url": source_url},
        "verification": {
            "archive_test": "passed",
            "artifact_executed": False,
            "code_signature": "not-verified-on-linux",
        },
    }


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        result = inspect(args)
    except InspectionError as exc:
        print(f"inspect-upstream: {exc}", file=sys.stderr)
        return 1
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
