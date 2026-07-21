#!/usr/bin/env bash
set -euo pipefail
umask 077

(( EUID != 0 )) || { printf 'refresh-private-computer-use must run as the desktop user\n' >&2; exit 2; }
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
snapshot="$repo_root/docs/upstream-snapshot.json"
source_release=${1:-$(readlink -f "$HOME/.local/opt/chatgpt-work-linux/current" 2>/dev/null || true)}
output=${CHATGPT_WORK_BUILD_DIR:-"$repo_root/.work/chatgpt-work-app"}
private_repo=${CHATGPT_WORK_COMPUTER_USE_REPO:-"$repo_root/../computer-use-linux"}

fail() {
  printf 'refresh-private-computer-use: %s\n' "$*" >&2
  exit 1
}

[[ -n $source_release && -d $source_release && ! -L $source_release ]] ||
  fail 'current immutable local application is missing'
[[ -x $source_release/start.sh && -f $source_release/.codex-linux/SHA256SUMS ]] ||
  fail 'current local application is incomplete'
(cd "$source_release" && sha256sum --check --quiet --strict .codex-linux/SHA256SUMS) ||
  fail 'current local application failed its checksum manifest'
[[ -d $private_repo/.git ]] || fail "private Computer Use checkout is missing: $private_repo"
[[ -z $(git -C "$private_repo" status --porcelain=v1 --untracked-files=all) ]] ||
  fail 'private Computer Use checkout is not clean'
[[ -z $(git -C "$repo_root" status --porcelain=v1 --untracked-files=all) ]] ||
  fail 'chatgpt-work-linux checkout must be clean before recording build provenance'

computer_use_archive=$("$repo_root/scripts/prepare-computer-use-linux.sh")
computer_use_commit=$(<"$computer_use_archive/.chatgpt-work-computer-use-commit")
computer_use_archive_sha256=$(<"$computer_use_archive/.chatgpt-work-computer-use-archive-sha256")
computer_use_tree_sha256=$(<"$computer_use_archive/.chatgpt-work-computer-use-integrity")
[[ $(git -C "$private_repo" rev-parse HEAD) == "$computer_use_commit" ]] ||
  fail 'private Computer Use checkout HEAD differs from the reviewed commit'

make -C "$private_repo" check
make -C "$private_repo" test-mcp
backend="$private_repo/target/release/codex-computer-use-linux"
cosmic="$private_repo/target/release/codex-computer-use-cosmic"
[[ -x $backend && -x $cosmic ]] || fail 'tested private Computer Use binaries are missing'

parent=$(dirname -- "$output")
stage="$parent/.stage-$(basename -- "$output")-private-computer-use-$$"
previous="$output.previous"
active_moved=0
cleanup() {
  if [[ $active_moved -eq 1 && ! -e $output && -e $previous ]]; then
    mv -- "$previous" "$output" || true
  fi
  rm -rf -- "$stage"
}
trap cleanup EXIT HUP INT TERM
mkdir -p -- "$parent"
mkdir -m 0700 -- "$stage"
cp -a --reflink=auto -- "$source_release/." "$stage/"
chmod -R u+w -- "$stage"

plugin_bin="$stage/resources/plugins/openai-bundled/plugins/computer-use/bin"
[[ -d $plugin_bin ]] || fail 'current application has no Computer Use plugin bin directory'
install -m 0755 -- "$backend" "$plugin_bin/codex-computer-use-linux"
install -m 0755 -- "$cosmic" "$plugin_bin/codex-computer-use-cosmic"
printf '%s\n' "$computer_use_commit" >"$stage/.codex-linux/private-computer-use-commit"

main_commit=$(git -C "$repo_root" rev-parse HEAD)
main_branch=$(git -C "$repo_root" branch --show-current)
main_remote=$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)
python3 - "$stage/.codex-linux/build-info.json" "$snapshot" \
  "$main_commit" "$main_branch" "$main_remote" \
  "$computer_use_commit" "$computer_use_archive_sha256" "$computer_use_tree_sha256" <<'PY'
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
snapshot_path = Path(sys.argv[2])
(
    main_commit,
    main_branch,
    main_remote,
    computer_use_commit,
    computer_use_archive,
    computer_use_tree,
) = sys.argv[3:]
value = json.loads(path.read_text(encoding="utf-8"))
snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
upstream = value.get("upstreamDmg")
expected_artifact = snapshot["artifact"]
expected = {
    "appVersion": snapshot["application"]["short_version"],
    "sha256": expected_artifact["sha256"],
    "sizeBytes": int(expected_artifact["size"]),
}
if not isinstance(upstream, dict):
    raise SystemExit("refresh-private-computer-use: source build has no upstreamDmg object")
for key, wanted in expected.items():
    if upstream.get(key) != wanted:
        raise SystemExit(f"refresh-private-computer-use: source build {key} differs from reviewed input")
upstream["fileName"] = expected_artifact["name"]
value["generatedAt"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
value["source"] = {
    "commit": main_commit,
    "shortCommit": main_commit[:12],
    "branch": main_branch,
    "remote": main_remote,
    "dirty": False,
    "provenance": "git",
}
value["computerUseSource"] = {
    "commit": computer_use_commit,
    "archiveSha256": computer_use_archive,
    "treeSha256": computer_use_tree,
    "privateLocalSource": True,
    "status": "under-work",
}
path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
PY

"$backend" --help | rg -q 'codex-computer-use-linux mcp' ||
  fail 'private Computer Use backend self-check failed'
rg -a -Fq \
  'ydotool is disabled on Wayland; a consented XDG Remote Desktop portal session is required' \
  "$plugin_bin/codex-computer-use-linux" ||
  fail 'private Computer Use portal-only Wayland guard is missing'

(
  cd "$stage"
  find . -type f ! -path './.codex-linux/SHA256SUMS' -print0 |
    LC_ALL=C sort -z | xargs -0 sha256sum >.codex-linux/SHA256SUMS
)
python3 "$repo_root/scripts/verify-reviewed-build.py" "$stage" "$snapshot"

if [[ -e $output ]]; then
  rm -rf -- "$previous"
  mv -- "$output" "$previous"
  active_moved=1
fi
mv -- "$stage" "$output"
active_moved=0
trap - EXIT HUP INT TERM
printf 'Refreshed local build with private Computer Use %s\n' "${computer_use_commit:0:12}"
