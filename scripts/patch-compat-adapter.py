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
    native_modules = args.adapter / "scripts/lib/native-modules.sh"

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

    old_npm_install = '''    echo '{"private":true}' > package.json

    info "Installing fresh sources from npm..."
    npm install \\
        "electron@$ELECTRON_VERSION" \\
        "$ELECTRON_REBUILD_PACKAGE" \\
        "$ELECTRON_REBUILD_NODE_ABI_PACKAGE" \\
        --save-dev \\
        --ignore-scripts >&2
    npm install "better-sqlite3@$bs3_build_ver" "node-pty@$npty_ver" --ignore-scripts >&2
'''
    new_npm_install = '''    local native_lock_dir="$SCRIPT_DIR/nix/native-modules"
    [ -f "$native_lock_dir/package.json" ] || error "Reviewed native-module package manifest is missing"
    [ -f "$native_lock_dir/package-lock.json" ] || error "Reviewed native-module lock is missing"
    cp "$native_lock_dir/package.json" "$native_lock_dir/package-lock.json" "$build_dir/"
    node - "$build_dir/package.json" "$ELECTRON_VERSION" "$bs3_build_ver" "$npty_ver" <<'JS'
const manifest = require(process.argv[2]);
const expected = {
  electron: process.argv[3],
  "better-sqlite3": process.argv[4],
  "node-pty": process.argv[5],
};
for (const [name, version] of Object.entries(expected)) {
  if (manifest.dependencies?.[name] !== version) {
    throw new Error(`Reviewed native-module lock ${name}@${manifest.dependencies?.[name] ?? "missing"} does not match required ${version}`);
  }
}
JS

    info "Installing integrity-locked native module sources from npm cache/registry..."
    npm ci --ignore-scripts --no-audit --no-fund >&2
'''
    npm_status = replace_exact(
        native_modules,
        old_npm_install,
        new_npm_install,
        "integrity-locked native module install",
    )

    old_electron_identity = '''    local electron_zip="electron-v${ELECTRON_VERSION}-linux-${electron_arch}.zip"
    if [ -n "${CODEX_ELECTRON_ZIP_SOURCE:-}" ]; then
        [ -f "$CODEX_ELECTRON_ZIP_SOURCE" ] || error "CODEX_ELECTRON_ZIP_SOURCE does not exist: $CODEX_ELECTRON_ZIP_SOURCE"
        info "Using Electron runtime archive: $CODEX_ELECTRON_ZIP_SOURCE"
        cp "$CODEX_ELECTRON_ZIP_SOURCE" "$WORK_DIR/electron.zip"
'''
    new_electron_identity = '''    local electron_zip="electron-v${ELECTRON_VERSION}-linux-${electron_arch}.zip"
    local expected_electron_sha256
    case "$ELECTRON_VERSION:$electron_arch" in
        42.3.0:x64) expected_electron_sha256=487a667ca6a734b958c16cff1df74d9d44d2c18a6cccdb4dd51f6301a356c420 ;;
        42.3.0:arm64) expected_electron_sha256=2a375ff973fb7bddc538a4f67b2141947e9d72513a1baa2beabec2a7f65cd0f0 ;;
        *) error "No reviewed Electron archive SHA-256 for $ELECTRON_VERSION/$electron_arch" ;;
    esac
    if [ -n "${CODEX_ELECTRON_ZIP_SOURCE:-}" ]; then
        [ -f "$CODEX_ELECTRON_ZIP_SOURCE" ] || error "CODEX_ELECTRON_ZIP_SOURCE does not exist: $CODEX_ELECTRON_ZIP_SOURCE"
        if ! printf '%s  %s\\n' "$expected_electron_sha256" "$CODEX_ELECTRON_ZIP_SOURCE" | sha256sum -c - >/dev/null 2>&1; then
            error "Provided Electron runtime archive failed reviewed SHA-256 verification"
        fi
        info "Using verified Electron runtime archive: $CODEX_ELECTRON_ZIP_SOURCE"
        cp "$CODEX_ELECTRON_ZIP_SOURCE" "$WORK_DIR/electron.zip"
'''
    electron_identity_status = replace_exact(
        native_modules,
        old_electron_identity,
        new_electron_identity,
        "reviewed Electron archive identity",
    )

    old_electron_copy = '''    cp "$cached_zip" "$WORK_DIR/electron.zip"
    mkdir -p "$INSTALL_DIR"
'''
    new_electron_copy = '''    if ! printf '%s  %s\\n' "$expected_electron_sha256" "$cached_zip" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$cached_zip"
        error "Cached Electron runtime archive failed reviewed SHA-256 verification"
    fi
    cp "$cached_zip" "$WORK_DIR/electron.zip"
    mkdir -p "$INSTALL_DIR"
'''
    electron_copy_status = replace_exact(
        native_modules,
        old_electron_copy,
        new_electron_copy,
        "cached Electron archive verification",
    )

    statuses = {
        contract_status,
        card_status,
        assertion_status,
        pattern_status,
        npm_status,
        electron_identity_status,
        electron_copy_status,
    }
    if len(statuses) != 1:
        raise SystemExit("patch-compat-adapter: adapter was only partially patched")
    print(f"patch-compat-adapter: {statuses.pop()}")


if __name__ == "__main__":
    main()
