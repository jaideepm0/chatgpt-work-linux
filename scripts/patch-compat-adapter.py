#!/usr/bin/env python3
"""Apply exact current-upstream drift fixes to a disposable adapter copy."""

from __future__ import annotations

import argparse
import os
from pathlib import Path


def replace_exact(path: Path, old: str, new: str, label: str) -> str:
    source = path.read_text(encoding="utf-8")
    if source.count(new) == 1 and source.count(old) == 0:
        return "already-applied"
    count = source.count(old)
    if count != 1 or source.count(new) != 0:
        raise SystemExit(
            f"patch-compat-adapter: expected one unpatched {label} in {path}, found {count}"
        )
    temporary = path.with_name(f".{path.name}.new-{os.getpid()}")
    temporary.write_text(source.replace(old, new, 1), encoding="utf-8")
    os.chmod(temporary, path.stat().st_mode)
    os.replace(temporary, path)
    return "applied"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("adapter", type=Path)
    args = parser.parse_args()

    implementation = args.adapter / "scripts/patches/impl/computer-use.js"
    install_flow = (
        args.adapter
        / "scripts/patches/core/all-linux/webview/computer-use-ui/patch.js"
    )

    old_contract = '''  const availabilityMarkerPattern =
    /([A-Za-z_$][\\w$]*)===`linux`&&\\(([A-Za-z_$][\\w$]*)=\\{\\.\\.\\.\\2,available:!0,isFetching:!1,isLoading:!1\\}\\);/;
  const cardMarker = "marketplaceName:`openai-bundled`";
  const hasAvailabilityMarker = availabilityMarkerPattern.test(currentSource);
  const hasCardMarker = currentSource.includes(cardMarker);

  if (hasAvailabilityMarker && hasCardMarker) {
    return currentSource;
  }
  if (hasAvailabilityMarker !== hasCardMarker) {
'''
    new_contract = '''  const availabilityMarkerPattern =
    /([A-Za-z_$][\\w$]*)===`linux`&&\\(([A-Za-z_$][\\w$]*)=\\{\\.\\.\\.\\2,available:!0,isFetching:!1,isLoading:!1\\}\\);/;
  const cardMarker = "marketplaceName:`openai-bundled`";
  const nativeCardSelectionPattern =
    /([A-Za-z_$][\\w$]*)=([A-Za-z_$][\\w$]*)\\(([A-Za-z_$][\\w$]*)\\.availablePlugins,([A-Za-z_$][\\w$]*),([A-Za-z_$][\\w$]*)\\)/g;
  const hasNativeCardContract = [...currentSource.matchAll(nativeCardSelectionPattern)].some(
    (match) => new RegExp(`(?:^|[,;])${match[4]}=\\`computer-use\\`(?:[,;]|$)`).test(currentSource),
  );
  const hasAvailabilityMarker = availabilityMarkerPattern.test(currentSource);
  const hasCardMarker = currentSource.includes(cardMarker) || hasNativeCardContract;

  if (hasAvailabilityMarker && hasCardMarker) {
    return currentSource;
  }
  if (hasAvailabilityMarker || currentSource.includes(cardMarker)) {
'''
    contract_status = replace_exact(
        implementation, old_contract, new_contract, "native Computer Use settings contract"
    )

    card_status = replace_exact(
        implementation,
        "  let cardChanged = false;\n",
        "  let cardChanged = hasNativeCardContract;\n",
        "native Computer Use card state",
    )
    assertion_status = replace_exact(
        implementation,
        "    patchedSource.includes(cardMarker)\n",
        "    (patchedSource.includes(cardMarker) || hasNativeCardContract)\n",
        "native Computer Use card assertion",
    )

    old_pattern = r'''    pattern: /^app-initial~artifact-tab-content\.electron~app-main~pull-request-route~pull-request-code-rev~jgoqfqy2-[^.]+\.js$/,
'''
    new_pattern = r'''    pattern: /^(?:app-initial~artifact-tab-content\.electron~app-main~pull-request-route~pull-request-code-rev~jgoqfqy2|app-initial~avatarOverlayCompositionSurface~artifact-tab-content\.electron~notebook-preview-~iaq4jiqv)-[^.]+\.js$/,
'''
    pattern_status = replace_exact(
        install_flow, old_pattern, new_pattern, "current Computer Use install-flow bundle"
    )

    statuses = {contract_status, card_status, assertion_status, pattern_status}
    if len(statuses) != 1:
        raise SystemExit("patch-compat-adapter: adapter was only partially patched")
    print(f"patch-compat-adapter: {statuses.pop()}")


if __name__ == "__main__":
    main()
