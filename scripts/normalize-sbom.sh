#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  printf 'usage: normalize-sbom.sh SBOM SOURCE_ROOT\n' >&2
  exit 2
fi

sbom=$1
source_root=$2
case $sbom in
  /*) ;;
  *) sbom="$PWD/$sbom" ;;
esac
case $source_root in
  /*) ;;
  *) printf 'normalize-sbom: SOURCE_ROOT must be absolute\n' >&2; exit 2 ;;
esac
[[ -f $sbom ]] || {
  printf 'normalize-sbom: SBOM does not exist: %s\n' "$sbom" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  printf 'normalize-sbom: jq is required\n' >&2
  exit 2
}

source_uri="path+file://$source_root"
canonical_uri='path+file:///usr/src/chatgpt-work-linux'
temporary="$sbom.tmp.$$"
cleanup() {
  rm -f -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

jq \
  --arg source "$source_uri" \
  --arg canonical "$canonical_uri" \
  'walk(
    if type == "string" and startswith($source)
    then $canonical + .[($source | length):]
    else .
    end
  )' \
  "$sbom" >"$temporary"

if grep -Fq -- "$source_root" "$temporary"; then
  printf 'normalize-sbom: source path remained after normalization\n' >&2
  exit 1
fi
jq -e '.bomFormat == "CycloneDX" and .specVersion == "1.5"' \
  "$temporary" >/dev/null
mv -f -- "$temporary" "$sbom"
trap - EXIT HUP INT TERM
