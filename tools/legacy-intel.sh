#!/usr/bin/env bash

# Optional 265Encode Intel Gen9/Skylake HEVC compatibility helper.
# Loaded only when modern hardware encoding has failed on a relevant Intel/i915 host.
[[ ${ENCODE265_LEGACY_HELPER_LOADED:-0} == 1 ]] && return 0
ENCODE265_LEGACY_HELPER_LOADED=1

ENCODE265_LEGACY_ERROR=''
ENCODE265_LEGACY_RUNTIME=''
ENCODE265_LEGACY_DRIVER_DIR=''
ENCODE265_LEGACY_COMMAND=()
ENCODE265_LEGACY_PROVEN_ID=''

encode265_legacy_cache_root() {
    printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/265Encode/intel-legacy-runtime"
}

encode265_legacy_download() {
    local url=$1 output=$2
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --retry 2 --connect-timeout 15 --output "$output" "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --tries=3 -O "$output" "$url" 2>/dev/null
    else
        return 1
    fi
}

encode265_legacy_hash_file() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "$file" | awk '{print $1}'
    else
        return 1
    fi
}

encode265_legacy_runtime_valid() {
    local runtime=$1 buildconf links
    [[ -x $runtime/bin/ffmpeg && -x $runtime/bin/ffprobe && -r $runtime/runtime-manifest.txt ]] || return 1
    grep -Fxq 'runtime_kind=intel-media-sdk-legacy' "$runtime/runtime-manifest.txt" || return 1
    grep -Fxq 'runtime_format=2' "$runtime/runtime-manifest.txt" || return 1
    grep -Fxq 'ffmpeg_legacy_hevc_extopts=disabled' "$runtime/runtime-manifest.txt" || return 1
    [[ -e $runtime/lib/libmfxhw64.so.1 || -n $(find "$runtime/lib" -maxdepth 1 -name 'libmfxhw64.so.1*' -print -quit 2>/dev/null) ]] || return 1
    buildconf=$(env INTEL_MEDIA_RUNTIME=MSDK LD_LIBRARY_PATH="$runtime/lib" "$runtime/bin/ffmpeg" -hide_banner -buildconf 2>&1) || return 1
    grep -Fq -- '--enable-libmfx' <<< "$buildconf" || return 1
    ! grep -Fq -- '--enable-libvpl' <<< "$buildconf" || return 1
    local encoders
    encoders=$(env INTEL_MEDIA_RUNTIME=MSDK LD_LIBRARY_PATH="$runtime/lib" "$runtime/bin/ffmpeg" -hide_banner -encoders 2>/dev/null) || return 1
    grep -Eq '[[:space:]]hevc_qsv([[:space:]]|$)' <<< "$encoders" || return 1
}

encode265_legacy_fetch_runtime() {
    local cache runtime base pointer selected asset tmp archive checksum expected actual
    cache=$(encode265_legacy_cache_root)
    runtime="$cache/linux-x86_64/runtime"
    if encode265_legacy_runtime_valid "$runtime"; then
        ENCODE265_LEGACY_RUNTIME=$runtime
        return 0
    fi
    mkdir -p "$cache/linux-x86_64" || return 1
    tmp=$(mktemp -d "$cache/linux-x86_64/.install.XXXXXX") || return 1
    base='https://github.com/andr8076/265Encode/releases/download/intel-legacy-runtime-latest'
    pointer="$tmp/265encode-intel-legacy-runtime-linux-x86_64.current"
    asset='265encode-intel-legacy-runtime-linux-x86_64.tar.gz'
    if encode265_legacy_download "$base/${pointer##*/}" "$pointer"; then
        selected=$(head -n1 "$pointer" | tr -d '\r\n')
        [[ $selected =~ ^265encode-intel-legacy-runtime-linux-x86_64-[0-9a-f]{40}\.tar\.gz$ ]] && asset=$selected
    fi
    archive="$tmp/$asset"
    checksum="$archive.sha256"
    printf '265Encode: downloading optional Intel legacy compatibility runtime...\n' >&2
    if ! encode265_legacy_download "$base/$asset" "$archive" || ! encode265_legacy_download "$base/$asset.sha256" "$checksum"; then
        ENCODE265_LEGACY_ERROR='265Encode legacy runtime release is not available'
        rm -rf "$tmp"; return 1
    fi
    expected=$(awk 'NF {print $1; exit}' "$checksum")
    actual=$(encode265_legacy_hash_file "$archive" 2>/dev/null || true)
    if [[ ! $expected =~ ^[0-9a-fA-F]{64}$ || ${expected,,} != ${actual,,} ]]; then
        ENCODE265_LEGACY_ERROR='legacy runtime checksum did not match'
        rm -rf "$tmp"; return 1
    fi
    if ! tar -tzf "$archive" | awk '{p=$0; sub(/^\.\//,"",p); if(p!="runtime" && p!~/^runtime\//) bad=1; n=split(p,a,"/"); for(i=1;i<=n;i++) if(a[i]=="..") bad=1} END{exit bad}' ||
       ! tar -xzf "$archive" -C "$tmp" || ! encode265_legacy_runtime_valid "$tmp/runtime"; then
        ENCODE265_LEGACY_ERROR='downloaded legacy runtime was unsafe, incomplete, or invalid'
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$runtime"
    mv "$tmp/runtime" "$runtime" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    ENCODE265_LEGACY_RUNTIME=$runtime
}

encode265_legacy_fetch_driver() {
    local runtime=$1 tmp package extracted driver staged
    if [[ -r $runtime/lib/dri/iHD_drv_video.so ]]; then
        ENCODE265_LEGACY_DRIVER_DIR="$runtime/lib/dri"
        return 0
    fi
    command -v dpkg-deb >/dev/null 2>&1 || { ENCODE265_LEGACY_ERROR='dpkg-deb is required for the private Intel driver extraction'; return 1; }
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/265encode-intel-driver.XXXXXX") || return 1
    printf '265Encode: downloading the Intel Full Feature VA driver into its private cache (no system installation)...\n' >&2
    if command -v apt-get >/dev/null 2>&1; then
        (cd "$tmp" && apt-get download intel-media-va-driver-non-free) >/dev/null 2>"$tmp/apt.log" || true
    elif command -v apt >/dev/null 2>&1; then
        (cd "$tmp" && apt download intel-media-va-driver-non-free) >/dev/null 2>"$tmp/apt.log" || true
    fi
    package=$(find "$tmp" -maxdepth 1 -type f -name 'intel-media-va-driver-non-free_*.deb' -print -quit)
    [[ -r $package ]] || { ENCODE265_LEGACY_ERROR='could not obtain intel-media-va-driver-non-free from configured repositories'; rm -rf "$tmp"; return 1; }
    extracted="$tmp/extracted"; mkdir -p "$extracted"
    dpkg-deb -x "$package" "$extracted" >/dev/null || { rm -rf "$tmp"; return 1; }
    driver=$(find "$extracted" -type f -name iHD_drv_video.so -print -quit)
    [[ -r $driver && ! -L $driver ]] || { ENCODE265_LEGACY_ERROR='downloaded Intel driver package did not contain iHD_drv_video.so'; rm -rf "$tmp"; return 1; }
    staged="$runtime/lib/.dri.new.$$"; rm -rf "$staged"; mkdir -p "$staged"
    cp "$driver" "$staged/iHD_drv_video.so" || { rm -rf "$tmp" "$staged"; return 1; }
    rm -rf "$runtime/lib/dri"; mv "$staged" "$runtime/lib/dri" || { rm -rf "$tmp" "$staged"; return 1; }
    rm -rf "$tmp"
    ENCODE265_LEGACY_DRIVER_DIR="$runtime/lib/dri"
}

encode265_legacy_command() {
    local runtime=${ENCODE265_LEGACY_RUNTIME:-} driver=${ENCODE265_LEGACY_DRIVER_DIR:-}
    [[ -x $runtime/bin/ffmpeg && -r $driver/iHD_drv_video.so ]] || return 1
    ENCODE265_LEGACY_COMMAND=(env INTEL_MEDIA_RUNTIME=MSDK "LD_LIBRARY_PATH=$runtime/lib" "LIBVA_DRIVERS_PATH=$driver" LIBVA_DRIVER_NAME=iHD "$runtime/bin/ffmpeg")
}

encode265_legacy_probe() {
    local runtime tmp raw output log actual status=0 identity
    [[ $(uname -s 2>/dev/null) == Linux && $(uname -m 2>/dev/null) == x86_64 ]] || return 1
    encode265_legacy_fetch_runtime || return 1
    runtime=$ENCODE265_LEGACY_RUNTIME
    encode265_legacy_fetch_driver "$runtime" || return 1
    identity=$(encode265_legacy_hash_file "$runtime/runtime-manifest.txt" 2>/dev/null || true)
    [[ -z $ENCODE265_LEGACY_PROVEN_ID || $ENCODE265_LEGACY_PROVEN_ID != "$identity" ]] || { encode265_legacy_command; return $?; }
    encode265_legacy_command || return 1
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/265encode-legacy-probe.XXXXXX") || return 1
    raw="$tmp/reference.nv12"; output="$tmp/output.mkv"; log="$tmp/encode.log"
    python3 - "$raw" <<'PY' || { rm -rf "$tmp"; return 1; }
import sys
w,h,frames=640,360,30
frame=bytes(w*h*3//2)
with open(sys.argv[1],'wb') as f:
    for _ in range(frames): f.write(frame)
PY
    local -a cmd=("${ENCODE265_LEGACY_COMMAND[@]}" -nostdin -hide_banner -v verbose -y -f rawvideo -pixel_format nv12 -video_size 640x360 -framerate 30 -i "$raw" -frames:v 30 -an -sn -dn -c:v hevc_qsv -load_plugin hevc_hw -low_power 0 -global_quality:v 28 -preset:v medium -f matroska "$output")
    if command -v timeout >/dev/null 2>&1; then timeout --kill-after=3 30 "${cmd[@]}" >/dev/null 2>"$log" || status=$?; else "${cmd[@]}" >/dev/null 2>"$log" || status=$?; fi
    if (( status != 0 )) || [[ ! -s $output ]] || ! grep -Fq 'Use Intel(R) Media SDK to create MFX session' "$log" || ! grep -Fq 'hardware accelerated implementation' "$log" || grep -Fq 'software implementation' "$log"; then
        ENCODE265_LEGACY_ERROR="real hardware HEVC probe failed (status $status)"
        rm -rf "$tmp"; return 1
    fi
    actual=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$output" 2>/dev/null | head -n1 || true)
    if [[ $actual != hevc ]] || ! ffmpeg -nostdin -hide_banner -v error -xerror -i "$output" -map '0:V:0' -f null - >/dev/null 2>&1; then
        ENCODE265_LEGACY_ERROR='legacy probe output verification failed'
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    ENCODE265_LEGACY_PROVEN_ID=$identity
    ENCODE265_LEGACY_ERROR=''
    return 0
}
