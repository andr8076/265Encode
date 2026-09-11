#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$HERE/../.." && pwd -P)
# shellcheck source=/dev/null
source "$HERE/versions.env"

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || {
    printf 'The legacy Intel compatibility runtime is currently supported only on Linux x86_64.\n' >&2
    exit 2
}

DEFAULT_WORK="$ROOT/.intel-legacy-runtime-build"
DEFAULT_OUT="$ROOT/dist/intel-legacy-runtime"
WORK=${ENCODE265_INTEL_LEGACY_WORK:-$DEFAULT_WORK}
OUT=${ENCODE265_INTEL_LEGACY_OUT:-$DEFAULT_OUT}
JOBS=${ENCODE265_INTEL_LEGACY_JOBS:-}
if [[ -z $JOBS ]]; then JOBS=$(nproc 2>/dev/null || printf 4); fi
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || { printf 'ENCODE265_INTEL_LEGACY_JOBS must be a positive integer.\n' >&2; exit 2; }

for cmd in cmake git make pkg-config gcc g++ nasm python3 readelf ldd; do
    command -v "$cmd" >/dev/null 2>&1 || { printf 'Missing build dependency: %s\n' "$cmd" >&2; exit 2; }
done
pkg-config --exists libdrm libva libva-drm || {
    printf 'Missing build headers: pkg-config must find libdrm, libva, and libva-drm.\n' >&2
    printf 'This builder never installs packages; provide dependencies in the build environment.\n' >&2
    exit 2
}

canonical_path() { python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(os.path.abspath(sys.argv[1])))
PY
}
WORK=$(canonical_path "$WORK")
OUT=$(canonical_path "$OUT")
BUILD_HOME=$(canonical_path "${HOME:-/nonexistent}")

validate_root() {
    local path=$1 label=$2 marker="$1/.265encode-intel-legacy-build-root"
    case $path in /|"$BUILD_HOME"|"$ROOT") printf 'Refusing unsafe %s directory: %s\n' "$label" "$path" >&2; exit 2 ;; esac
    [[ $ROOT != "$path/"* ]] || { printf 'Refusing %s directory that contains the repository: %s\n' "$label" "$path" >&2; exit 2; }
    [[ ! -e $path || -d $path ]] || { printf '%s path is not a directory: %s\n' "$label" "$path" >&2; exit 2; }
    if [[ -d $path && -n $(find "$path" -mindepth 1 -maxdepth 1 -print -quit) && ! -f $marker ]]; then
        printf 'Refusing to clean unmarked non-empty %s directory: %s\n' "$label" "$path" >&2
        exit 2
    fi
}
prepare_root() {
    local path=$1
    rm -rf -- "$path"
    mkdir -p -- "$path"
    : > "$path/.265encode-intel-legacy-build-root"
}
validate_root "$WORK" work
validate_root "$OUT" output
[[ $WORK != "$OUT" && $WORK != "$OUT/"* && $OUT != "$WORK/"* ]] || {
    printf 'Work and output directories must not overlap.\n' >&2; exit 2;
}
prepare_root "$WORK"
prepare_root "$OUT"
mkdir -p "$WORK/src" "$WORK/prefix" "$WORK/ffmpeg-prefix" \
    "$OUT/runtime/bin" "$OUT/runtime/lib" "$OUT/runtime/licenses"

printf 'Building discontinued Intel Media SDK %s at pinned commit %s\n' "$INTEL_MEDIA_SDK_VERSION" "$INTEL_MEDIA_SDK_COMMIT"
git clone --filter=blob:none "$INTEL_MEDIA_SDK_GIT_URL" "$WORK/src/MediaSDK"
git -C "$WORK/src/MediaSDK" checkout --detach "$INTEL_MEDIA_SDK_COMMIT"
[[ $(git -C "$WORK/src/MediaSDK" rev-parse HEAD) == "$INTEL_MEDIA_SDK_COMMIT" ]] || { printf 'Media SDK pin mismatch.\n' >&2; exit 3; }
cmake -S "$WORK/src/MediaSDK" -B "$WORK/mediasdk-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$WORK/prefix" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_ALL=OFF \
    -DBUILD_RUNTIME=ON \
    -DBUILD_DISPATCHER=ON \
    -DBUILD_SAMPLES=OFF \
    -DBUILD_TUTORIALS=OFF \
    -DBUILD_TOOLS=OFF \
    -DBUILD_TESTS=OFF \
    -DENABLE_OPENCL=OFF \
    -DENABLE_X11_DRI3=OFF \
    -DENABLE_WAYLAND=OFF
cmake --build "$WORK/mediasdk-build" --parallel "$JOBS"
cmake --install "$WORK/mediasdk-build"

printf 'Building isolated FFmpeg %s against legacy libmfx only\n' "$FFMPEG_VERSION"
git clone --filter=blob:none "$FFMPEG_GIT_URL" "$WORK/src/FFmpeg"
git -C "$WORK/src/FFmpeg" checkout --detach "$FFMPEG_COMMIT"
[[ $(git -C "$WORK/src/FFmpeg" rev-parse HEAD) == "$FFMPEG_COMMIT" ]] || { printf 'FFmpeg pin mismatch.\n' >&2; exit 3; }
git -C "$WORK/src/FFmpeg" apply --check "$HERE/ffmpeg-hevc-legacy-no-extopts.patch"
git -C "$WORK/src/FFmpeg" apply "$HERE/ffmpeg-hevc-legacy-no-extopts.patch"
grep -Fq '265Encode legacy Intel compatibility runtime' \
    "$WORK/src/FFmpeg/libavcodec/qsvenc.c" || { printf 'Legacy HEVC compatibility patch was not applied.\n' >&2; exit 3; }
export PKG_CONFIG_PATH="$WORK/prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
(
    cd "$WORK/src/FFmpeg"
    ./configure \
        --prefix="$WORK/ffmpeg-prefix" \
        --disable-doc \
        --disable-debug \
        --disable-shared \
        --enable-static \
        --disable-network \
        --enable-libdrm \
        --enable-vaapi \
        --enable-libmfx \
        --disable-libvpl \
        --extra-cflags="-I$WORK/prefix/include" \
        --extra-ldflags="-L$WORK/prefix/lib -Wl,-rpath,\$ORIGIN/../lib"
    grep -Fxq 'CONFIG_LIBMFX=yes' ffbuild/config.mak || { printf 'FFmpeg did not enable libmfx.\n' >&2; exit 3; }
    ! grep -Fxq 'CONFIG_LIBVPL=yes' ffbuild/config.mak || { printf 'FFmpeg unexpectedly enabled libvpl.\n' >&2; exit 3; }
    make -j "$JOBS" ffmpeg ffprobe
)

cp -- "$WORK/src/FFmpeg/ffmpeg" "$OUT/runtime/bin/ffmpeg"
cp -- "$WORK/src/FFmpeg/ffprobe" "$OUT/runtime/bin/ffprobe"
cp -P -- "$WORK/prefix/lib/"libmfx.so* "$OUT/runtime/lib/"
cp -P -- "$WORK/prefix/lib/"libmfxhw64.so* "$OUT/runtime/lib/"
cp -- "$WORK/src/MediaSDK/LICENSE" "$OUT/runtime/licenses/Intel-Media-SDK-LICENSE"
cp -- "$WORK/src/FFmpeg/LICENSE.md" "$OUT/runtime/licenses/FFmpeg-LICENSE.md"

FFMPEG_BUILD=$(bash "$HERE/with-runtime.sh" "$OUT/runtime" "$OUT/runtime/bin/ffmpeg" -hide_banner -version 2>&1 | head -n1)
{
    printf 'runtime_format=%s\n' "$INTEL_LEGACY_RUNTIME_FORMAT"
    printf 'runtime_kind=intel-media-sdk-legacy\n'
    printf 'lifecycle=discontinued-unmaintained-compatibility-only\n'
    printf 'media_sdk_version=%s\n' "$INTEL_MEDIA_SDK_VERSION"
    printf 'media_sdk_commit=%s\n' "$INTEL_MEDIA_SDK_COMMIT"
    printf 'ffmpeg_version=%s\n' "$FFMPEG_VERSION"
    printf 'ffmpeg_commit=%s\n' "$FFMPEG_COMMIT"
    printf 'ffmpeg_legacy_hevc_extopts=disabled\n'
    printf 'ffmpeg_build=%s\n' "$FFMPEG_BUILD"
    printf 'platform=%s\n' "$(uname -s)"
    printf 'architecture=%s\n' "$(uname -m)"
} > "$OUT/runtime/runtime-manifest.txt"

bash "$HERE/inspect.sh" "$OUT/runtime"
printf 'Compatibility runtime created at %s/runtime\n' "$OUT"
printf 'This creates and validates the isolated runtime only; 265Encode proves GPU capability with a real encode at runtime.\n'
