#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

usage() {
    printf 'Usage: %s RUNTIME_DIR COMMAND [ARG ...]\n' "${0##*/}" >&2
    exit 2
}

(( $# >= 2 )) || usage
RUNTIME=$1
shift
RUNTIME=$(cd -- "$RUNTIME" 2>/dev/null && pwd -P) || {
    printf 'Legacy Intel runtime directory does not exist: %s\n' "$RUNTIME" >&2
    exit 2
}
[[ -d $RUNTIME/lib ]] || { printf 'Legacy Intel runtime has no lib directory: %s\n' "$RUNTIME" >&2; exit 2; }

# These variables apply only to the child process. In particular, do not export
# INTEL_MEDIA_RUNTIME or a libva driver choice into 265Encode globally.
exec env \
    INTEL_MEDIA_RUNTIME=MSDK \
    LD_LIBRARY_PATH="$RUNTIME/lib" \
    "$@"
