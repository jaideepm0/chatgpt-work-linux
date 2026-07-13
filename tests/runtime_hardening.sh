#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d -t chatgpt-work-runtime-test.XXXXXX)
cleanup() {
  rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

anchor='process.platform===`linux`&&codexLinuxPrewarmHotkeyWindow()'
predicate='function ext(e){return e===`macOS`||e===`windows`}'
availability='featureName:`computer_use`;g=rxt({areRequiredFeaturesEnabled:h,enabled:i,isAnyFeatureLoading:m,isComputerUseGateEnabled:s,isHostCompatiblePlatform:ext(o),isPlatformLoading:a,windowType:`electron`})'
printf 'prefix%smiddle%snext%ssuffix' "$anchor" "$predicate" "$availability" >"$temporary/app.asar"
before_size=$(stat -c %s "$temporary/app.asar")
python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/app.asar"
after_size=$(stat -c %s "$temporary/app.asar")
[[ $before_size == "$after_size" ]] || {
  printf 'runtime_hardening: ASAR patch changed byte length\n' >&2
  exit 1
}
! rg -q 'codexLinuxPrewarmHotkeyWindow' "$temporary/app.asar" || {
  printf 'runtime_hardening: startup prewarm call remains\n' >&2
  exit 1
}
rg -Fq 'function ext(e){return e===`linux`||e===`windows`}' "$temporary/app.asar" || {
  printf 'runtime_hardening: Computer Use Linux availability predicate is missing\n' >&2
  exit 1
}
rg -Fq 'areRequiredFeaturesEnabled:1,enabled:i,isAnyFeatureLoading:0,isComputerUseGateEnabled:1,isHostCompatiblePlatform:ext(o)' "$temporary/app.asar" || {
  printf 'runtime_hardening: Computer Use Linux feature gates remain conditional\n' >&2
  exit 1
}
if python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/app.asar" >/dev/null 2>&1; then
  printf 'runtime_hardening: patcher accepted an already-patched input\n' >&2
  exit 1
fi

printf '%s%s%s%s' "$anchor" "$anchor" "$predicate" "$availability" >"$temporary/ambiguous.asar"
if python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/ambiguous.asar" >/dev/null 2>&1; then
  printf 'runtime_hardening: patcher accepted an ambiguous input\n' >&2
  exit 1
fi

printf '%s%s' "$anchor" "$availability" >"$temporary/missing-computer-use-predicate.asar"
if python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/missing-computer-use-predicate.asar" >/dev/null 2>&1; then
  printf 'runtime_hardening: patcher accepted a missing Computer Use predicate\n' >&2
  exit 1
fi

printf '%s%s' "$anchor" "$predicate" >"$temporary/missing-computer-use-call.asar"
if python3 "$repo_root/scripts/patch-work-asar.py" "$temporary/missing-computer-use-call.asar" >/dev/null 2>&1; then
  printf 'runtime_hardening: patcher accepted a missing Computer Use availability call\n' >&2
  exit 1
fi

valid_report="$temporary/valid-report.json"
printf '%s\n' '{"patches":[' \
  '{"name":"linux-computer-use-ui-feature","status":"applied"},' \
  '{"name":"linux-computer-use-plugin-gate","status":"already-applied"},' \
  '{"name":"linux-computer-use-native-desktop-apps","status":"applied"},' \
  '{"name":"linux-computer-use-ui-availability","status":"applied"},' \
  '{"name":"linux-computer-use-install-flow","status":"applied"}' \
  ']}' | tr -d '\n' >"$valid_report"
python3 "$repo_root/scripts/validate-work-patch-report.py" "$valid_report" >/dev/null

invalid_report="$temporary/invalid-report.json"
sed 's/"linux-computer-use-ui-availability","status":"applied"/"linux-computer-use-ui-availability","status":"skipped-disabled"/' \
  "$valid_report" >"$invalid_report"
if python3 "$repo_root/scripts/validate-work-patch-report.py" "$invalid_report" >/dev/null 2>&1; then
  printf 'runtime_hardening: validator accepted a disabled Computer Use UI patch\n' >&2
  exit 1
fi

server_fixture="$temporary/server.rs"
python3 - "$repo_root/scripts/patch-computer-use-wayland.py" "$server_fixture" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("wayland_patch", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
with open(sys.argv[2], "w", encoding="utf-8") as fixture:
    fixture.write("prefix\n")
    for _name, originals, _patched in module.TRANSFORMS:
        fixture.write(originals[0])
        fixture.write("\n")
    fixture.write("suffix\n")
PY
python3 "$repo_root/scripts/patch-computer-use-wayland.py" "$server_fixture" >/dev/null
rg -Fq 'Action sent through the Wayland remote desktop portal.' "$server_fixture" || {
  printf 'runtime_hardening: Wayland press_key portal patch is missing\n' >&2
  exit 1
}
rg -Fq 'let focus = match self.focus_target_for_input(&params.window_target()).await' "$server_fixture" || {
  printf 'runtime_hardening: final keyboard focus revalidation is missing\n' >&2
  exit 1
}
rg -Fq 'ydotool is disabled on Wayland; a consented XDG Remote Desktop portal session is required' "$server_fixture" || {
  printf 'runtime_hardening: Wayland ydotool fail-closed guard is missing\n' >&2
  exit 1
}
rg -Fq 'if self.should_prefer_kde_clipboard_text_backend() && !params.window_target().has_target()' "$server_fixture" || {
  printf 'runtime_hardening: targeted KDE clipboard race guard is missing\n' >&2
  exit 1
}
rg -Fq 'fn should_prefer_portal_pointer_backend(&self) -> bool {' "$server_fixture" || {
  printf 'runtime_hardening: Wayland portal pointer preference is missing\n' >&2
  exit 1
}
python3 "$repo_root/scripts/patch-computer-use-wayland.py" "$server_fixture" >/dev/null
printf 'drifted\n' >"$server_fixture"
if python3 "$repo_root/scripts/patch-computer-use-wayland.py" "$server_fixture" >/dev/null 2>&1; then
  printf 'runtime_hardening: Wayland press_key patcher accepted drifted source\n' >&2
  exit 1
fi

printf 'runtime_hardening: all tests passed\n'
