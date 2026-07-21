#!/usr/bin/env bash
set -euo pipefail
case ${1:-} in
  doctor)
    printf '%s\n' '{"application":"fixture","packaged":true}'
    ;;
  computer-use-doctor)
    printf '%s\n' 'fixture computer use healthy'
    ;;
  *)
    printf '%s\n' 'fixture launcher'
    ;;
esac
