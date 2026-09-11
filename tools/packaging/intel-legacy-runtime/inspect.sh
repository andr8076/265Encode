#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
RUNTIME=${1:-}
[[ -n $RUNTIME ]] || { printf 'Usage: %s RUNTIME_DIR\n' "${0##*/}" >&2; exit 2; }
RUNTIME=$(cd -- "$RUNTIME" 2>/dev/null && pwd -P) || {
    printf 'UNUSABLE Legacy Intel runtime directory does not exist: %s\n' "$RUNTIME" >&2
    exit 2
}
FFMPEG="$RUNTIME/bin/ffmpeg"
MANIFEST="$RUNTIME/runtime-manifest.txt"
READELF=${ENCODE265_LEGACY_READELF:-readelf}
LDD=${ENCODE265_LEGACY_LDD:-ldd}

fail() { printf 'UNUSABLE %s\n' "$*" >&2; exit 1; }
[[ -x $FFMPEG ]] || fail "missing executable: $FFMPEG"
[[ -f $MANIFEST ]] || fail "missing runtime manifest: $MANIFEST"
grep -Fxq 'runtime_kind=intel-media-sdk-legacy' "$MANIFEST" || fail 'manifest does not identify the legacy Intel Media SDK runtime'
grep -Fxq 'runtime_format=2' "$MANIFEST" || fail 'unsupported or missing legacy runtime format'
grep -Fxq 'ffmpeg_legacy_hevc_extopts=disabled' "$MANIFEST" || fail 'legacy HEVC FFmpeg compatibility patch identity is missing'
command -v "$READELF" >/dev/null 2>&1 || fail "required inspector is unavailable: $READELF"
command -v "$LDD" >/dev/null 2>&1 || fail "required inspector is unavailable: $LDD"

BUILDCONF=$(bash "$HERE/with-runtime.sh" "$RUNTIME" "$FFMPEG" -hide_banner -buildconf 2>&1) || fail 'compatibility FFmpeg could not start'
grep -Fq -- '--enable-libmfx' <<< "$BUILDCONF" || fail 'compatibility FFmpeg was not built with libmfx'
! grep -Fq -- '--enable-libvpl' <<< "$BUILDCONF" || fail 'compatibility FFmpeg was built with oneVPL'

DYNAMIC=$("$READELF" -d "$FFMPEG" 2>&1) || fail 'could not inspect compatibility FFmpeg dynamic dependencies'
grep -Eq 'Shared library: \[libmfx\.so(\.1)?\]' <<< "$DYNAMIC" || fail 'compatibility FFmpeg does not link to legacy libmfx'
! grep -Eq 'Shared library: \[libvpl\.so' <<< "$DYNAMIC" || fail 'compatibility FFmpeg links to oneVPL'

LINKS=$(bash "$HERE/with-runtime.sh" "$RUNTIME" "$LDD" "$FFMPEG" 2>&1) || fail 'could not resolve compatibility FFmpeg libraries'
MFX_LINK=$(awk '/libmfx\.so/{for (i=1; i<=NF; i++) if ($i ~ /^\//) {print $i; exit}}' <<< "$LINKS")
[[ -n $MFX_LINK ]] || fail 'legacy libmfx dependency did not resolve'
MFX_LINK=$(readlink -f -- "$MFX_LINK")
case $MFX_LINK in "$RUNTIME"/lib/*) ;; *) fail "legacy libmfx resolved outside the compatibility runtime: $MFX_LINK" ;; esac
! grep -Eq 'libvpl\.so|libmfx-gen\.so' <<< "$LINKS" || fail 'oneVPL was resolved in the compatibility process'

find "$RUNTIME/lib" -maxdepth 1 \( -name 'libmfxhw64.so.1' -o -name 'libmfxhw64.so.1.*' \) -print -quit | grep -q . || \
    fail 'bundled legacy hardware implementation libmfxhw64.so.1 is missing'

ENCODERS=$(bash "$HERE/with-runtime.sh" "$RUNTIME" "$FFMPEG" -hide_banner -encoders 2>&1) || fail 'could not list compatibility FFmpeg encoders'
grep -Eq '[[:space:]]hevc_qsv([[:space:]]|$)' <<< "$ENCODERS" || fail 'compatibility FFmpeg does not expose hevc_qsv'

printf 'READY Runtime integrity: FFmpeg/libmfx resolve to the isolated Intel Media SDK compatibility runtime\n'
printf 'INFO Runtime: %s\n' "$RUNTIME"
printf 'INFO Legacy libmfx: %s\n' "$MFX_LINK"
printf 'INFO Encoder listing is not a capability proof; 265Encode performs a real encode probe on the target GPU.\n'
