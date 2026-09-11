#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path

PATH = Path("265Encode.sh")
text = PATH.read_text(encoding="utf-8")


def replace_once(old: str, new: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match, found {count}: {old[:100]!r}")
    text = text.replace(old, new, 1)


def regex_once(pattern: str, replacement: str) -> None:
    global text
    text, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE | re.DOTALL)
    if count != 1:
        raise SystemExit(f"expected exactly one regex match, found {count}: {pattern!r}")


replace_once('SCRIPT_VERSION="2.7"', 'SCRIPT_VERSION="2.8"')

replace_once(
    'LEGACY_INTEL_HELPER_SHA256="cc6138e22f2fe22834e99ace011d8ae1fa8a021e7f5e1cbb281596f514756c38"\n'
    'LEGACY_INTEL_DEVICE_ID=""\n'
    'LEGACY_INTEL_ADDON_LOADED="no"\n'
    'LEGACY_INTEL_FFMPEG_COMMAND=()\n',
    'LEGACY_INTEL_HELPER_SHA256="cc6138e22f2fe22834e99ace011d8ae1fa8a021e7f5e1cbb281596f514756c38"\n'
    'LEGACY_INTEL_CALIBRATOR_URL="https://raw.githubusercontent.com/andr8076/265Encode/main/tools/legacy-intel-calibration.py"\n'
    'LEGACY_INTEL_CALIBRATOR_SHA256="89988de003674bd6d1074dbfc7bb7960ebff274d168264e2298ee2bc967d7524"\n'
    'LEGACY_INTEL_DEVICE_ID=""\n'
    'LEGACY_INTEL_ADDON_LOADED="no"\n'
    'LEGACY_INTEL_FFMPEG_COMMAND=()\n'
    'LEGACY_INTEL_CALIBRATION="${ENCODE265_INTEL_LEGACY_CALIBRATION:-1}"\n'
    'LEGACY_INTEL_CALIBRATOR=""\n'
    'LEGACY_INTEL_QUALITY_RUNTIME=""\n'
    'LEGACY_INTEL_PLAN_NAME="safe"\n'
)

replace_once(
    'HARDWARE_QP="24"\nAUDIO_MODE="aac"',
    'HARDWARE_QP="24"\nHARDWARE_QP_EXPLICIT="no"\nAUDIO_MODE="aac"',
)

replace_once(
    '      --qp NUMBER          Hardware constant-quality QP, default: 24\n'
    '      --vaapi-device PATH  Force a VA-API render node, for example\n',
    '      --qp NUMBER          Manual hardware QP, default: 24\n'
    '                           (disables legacy Intel auto-calibration)\n'
    '      --vaapi-device PATH  Force a VA-API render node, for example\n',
)

replace_once(
    '      --debug-hardware     Show hardware probe commands and full errors\n'
    '      --no-legacy-intel    Disable optional legacy Intel fallback for this run\n',
    '      --debug-hardware     Show hardware probe commands and full errors\n'
    '      --legacy-calibration Enable bounded P530 content calibration (default)\n'
    '      --no-legacy-calibration\n'
    '                           Use the verified safe P530 preset without sampling\n'
    '      --no-legacy-intel    Disable optional legacy Intel fallback for this run\n',
)

replace_once(
    '            --qp)\n'
    '                require_value "$1" "${2-}"\n'
    '                HARDWARE_QP="$2"\n'
    '                shift 2\n'
    '                ;;\n',
    '            --qp)\n'
    '                require_value "$1" "${2-}"\n'
    '                HARDWARE_QP="$2"\n'
    '                HARDWARE_QP_EXPLICIT="yes"\n'
    '                shift 2\n'
    '                ;;\n',
)

replace_once(
    '            --no-legacy-intel)\n'
    '                LEGACY_INTEL_AUTO=0\n'
    '                shift\n'
    '                ;;\n',
    '            --legacy-calibration)\n'
    '                LEGACY_INTEL_CALIBRATION=1\n'
    '                shift\n'
    '                ;;\n'
    '            --no-legacy-calibration)\n'
    '                LEGACY_INTEL_CALIBRATION=0\n'
    '                shift\n'
    '                ;;\n'
    '            --no-legacy-intel)\n'
    '                LEGACY_INTEL_AUTO=0\n'
    '                shift\n'
    '                ;;\n',
)

legacy_anchor = '''try_legacy_intel_hw() {
    legacy_intel_host_present || return 1
    load_legacy_intel_addon || return 1
    debug_log "Running a bounded real HEVC encode probe on the legacy Intel path."
    if ! encode265_legacy_probe; then
        debug_log "Legacy Intel HEVC probe failed: ${ENCODE265_LEGACY_ERROR:-unknown error}"
        return 1
    fi
    encode265_legacy_command || return 1
    LEGACY_INTEL_FFMPEG_COMMAND=("${ENCODE265_LEGACY_COMMAND[@]}")
    debug_log "Legacy Intel HEVC hardware acceleration was proven and selected."
    return 0
}
'''

legacy_functions = r'''

legacy_intel_quality_runtime_valid() {
    local runtime="$1"
    local filters
    [[ -x "$runtime/bin/ffmpeg" && -x "$runtime/bin/ffprobe" && -r "$runtime/runtime-manifest.txt" ]] || return 1
    filters="$(env LD_LIBRARY_PATH="$runtime/lib" "$runtime/bin/ffmpeg" -hide_banner -filters 2>&1)" || return 1
    grep -Eq '(^|[[:space:]])libvmaf([[:space:]]|$)' <<< "$filters"
}

legacy_intel_fetch_quality_runtime() {
    local cache runtime base pointer selected asset tmp archive checksum expected actual
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/265Encode/quality-runtime"
    runtime="$cache/linux-x86_64/runtime"
    if legacy_intel_quality_runtime_valid "$runtime"; then
        LEGACY_INTEL_QUALITY_RUNTIME="$runtime"
        return 0
    fi

    mkdir -p "$cache/linux-x86_64" || return 1
    tmp="$(mktemp -d "$cache/linux-x86_64/.install.XXXXXX")" || return 1
    base='https://github.com/andr8076/265Encode/releases/download/quality-runtime-latest'
    pointer="$tmp/265encode-quality-runtime-linux-x86_64.current"
    if ! legacy_intel_download "$base/${pointer##*/}" "$pointer"; then
        rm -rf "$tmp"
        return 1
    fi
    selected="$(head -n1 "$pointer" | tr -d '\r\n')"
    if [[ ! "$selected" =~ ^265encode-quality-runtime-linux-x86_64-[0-9a-f]{40}\.tar\.gz$ ]]; then
        rm -rf "$tmp"
        return 1
    fi
    asset="$selected"
    archive="$tmp/$asset"
    checksum="$archive.sha256"
    printf '265Encode: downloading one-time VMAF runtime for legacy Intel calibration...\n' >&2
    if ! legacy_intel_download "$base/$asset" "$archive" || ! legacy_intel_download "$base/$asset.sha256" "$checksum"; then
        rm -rf "$tmp"
        return 1
    fi
    expected="$(awk 'NF {print $1; exit}' "$checksum")"
    actual="$(legacy_intel_hash_file "$archive" 2>/dev/null || true)"
    if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ || "${expected,,}" != "${actual,,}" ]]; then
        rm -rf "$tmp"
        return 1
    fi
    if ! tar -tzf "$archive" | awk '{p=$0; sub(/^\.\//,"",p); if(p!="runtime" && p!~/^runtime\//) bad=1; n=split(p,a,"/"); for(i=1;i<=n;i++) if(a[i]=="..") bad=1} END{exit bad}' ||
       ! tar -xzf "$archive" -C "$tmp" || ! legacy_intel_quality_runtime_valid "$tmp/runtime"; then
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$runtime"
    mv "$tmp/runtime" "$runtime" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    LEGACY_INTEL_QUALITY_RUNTIME="$runtime"
}

legacy_intel_fetch_calibrator() {
    local cache calibrator tmp actual
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/265Encode/intel-legacy-addon"
    calibrator="$cache/legacy-intel-calibration.py"
    mkdir -p "$cache" || return 1
    if [[ -r "$calibrator" ]]; then
        actual="$(legacy_intel_hash_file "$calibrator" 2>/dev/null || true)"
    fi
    if [[ "${actual:-}" != "$LEGACY_INTEL_CALIBRATOR_SHA256" ]]; then
        tmp="$calibrator.download.$$"
        legacy_intel_download "$LEGACY_INTEL_CALIBRATOR_URL" "$tmp" || { rm -f "$tmp"; return 1; }
        actual="$(legacy_intel_hash_file "$tmp" 2>/dev/null || true)"
        [[ "$actual" == "$LEGACY_INTEL_CALIBRATOR_SHA256" ]] || { rm -f "$tmp"; return 1; }
        mv -f "$tmp" "$calibrator" || return 1
    fi
    LEGACY_INTEL_CALIBRATOR="$calibrator"
}

legacy_intel_calibration_enabled() {
    case "${LEGACY_INTEL_CALIBRATION:-1}" in
        0|false|FALSE|no|NO|off|OFF) return 1 ;;
    esac
    return 0
}

legacy_intel_set_plan_args() {
    local plan="$1"
    case "$plan" in
        compact)
            VIDEO_ENCODER_ARGS=(
                -c:v hevc_qsv -load_plugin hevc_hw -low_power 0
                -q:v 19 -preset:v veryslow -pix_fmt nv12
                -bf 7 -refs 4 -g 600
            )
            ;;
        efficient)
            VIDEO_ENCODER_ARGS=(
                -c:v hevc_qsv -load_plugin hevc_hw -low_power 0
                -q:v 17 -preset:v veryslow -pix_fmt nv12
                -bf 15 -refs 5 -g 600
            )
            ;;
        balanced)
            VIDEO_ENCODER_ARGS=(
                -c:v hevc_qsv -load_plugin hevc_hw -low_power 0
                -q:v 18
                -i_qfactor -0.7777777778 -i_qoffset 0
                -b_qfactor 1.0555555556 -b_qoffset 0
                -preset:v veryslow -pix_fmt nv12
                -bf 6 -refs 4 -g 600
            )
            ;;
        manual)
            VIDEO_ENCODER_ARGS=(
                -c:v hevc_qsv -load_plugin hevc_hw -low_power 0
                -q:v "$HARDWARE_QP" -preset:v veryslow -pix_fmt nv12
                -bf 6 -refs 4 -g 600
            )
            ;;
        safe|*)
            plan="safe"
            VIDEO_ENCODER_ARGS=(
                -c:v hevc_qsv -load_plugin hevc_hw -low_power 0
                -q:v 19
                -i_qfactor -0.8421052632 -i_qoffset 0
                -b_qfactor 0.9473684211 -b_qoffset 0
                -preset:v veryslow -pix_fmt nv12
                -bf 6 -refs 4 -g 600
            )
            ;;
    esac
    LEGACY_INTEL_PLAN_NAME="$plan"
}

configure_legacy_intel_file() {
    local input_file="$1"
    local cache result plan ratio windows provenance ratio_percent log

    if [[ "$HARDWARE_QP_EXPLICIT" == "yes" ]]; then
        legacy_intel_set_plan_args manual
        echo "Legacy Intel tuning: manual QP ${HARDWARE_QP} (auto-calibration bypassed)."
        return 0
    fi

    legacy_intel_set_plan_args safe
    if ! legacy_intel_calibration_enabled; then
        echo "Legacy Intel tuning: verified safe preset (calibration disabled)."
        return 0
    fi
    if [[ "$DRY_RUN" == "yes" ]]; then
        echo "Legacy Intel tuning: dry-run shows the verified safe fallback; calibration runs only for a real encode."
        return 0
    fi
    if ! legacy_intel_fetch_quality_runtime || ! legacy_intel_fetch_calibrator; then
        echo "Legacy Intel tuning: calibration unavailable; using verified safe preset."
        return 0
    fi

    cache="${XDG_CACHE_HOME:-$HOME/.cache}/265Encode/intel-legacy-calibration"
    mkdir -p "$cache" || return 0
    log="$cache/last-calibration-error.log"
    result="$(python3 "$LEGACY_INTEL_CALIBRATOR" \
        --source "$input_file" \
        --legacy-runtime "$ENCODE265_LEGACY_RUNTIME" \
        --driver-dir "$ENCODE265_LEGACY_DRIVER_DIR" \
        --quality-runtime "$LEGACY_INTEL_QUALITY_RUNTIME" \
        --cache-root "$cache" 2>"$log")" || {
            debug_log "Legacy Intel calibration failed; see $log"
            echo "Legacy Intel tuning: calibration failed; using verified safe preset."
            return 0
        }

    IFS='|' read -r plan ratio windows provenance <<< "$result"
    case "$plan" in
        compact|efficient|balanced|safe) ;;
        *)
            debug_log "Legacy Intel calibrator returned invalid plan: $result"
            echo "Legacy Intel tuning: invalid calibration result; using verified safe preset."
            return 0
            ;;
    esac
    legacy_intel_set_plan_args "$plan"
    ratio_percent="$(awk -v ratio="${ratio:-1}" 'BEGIN { printf "%.1f", ratio * 100 }')"
    if [[ "$provenance" == "cache" ]]; then
        echo "Legacy Intel tuning: $plan preset (cached; sampled size ${ratio_percent}% of safe)."
    else
        echo "Legacy Intel tuning: $plan preset selected from ${windows:-0} bounded samples (sampled size ${ratio_percent}% of safe)."
    fi
}
'''

replace_once(legacy_anchor, legacy_anchor + legacy_functions)

legacy_block_pattern = r'''^        intel-legacy\)\n            ACTIVE_ENCODER="Intel Skylake Legacy Quick Sync"\n            FFMPEG_COMMAND=\("\$\{LEGACY_INTEL_FFMPEG_COMMAND\[@\]\}"\)\n            VIDEO_ENCODER_ARGS=\(\n                -c:v hevc_qsv\n                -load_plugin hevc_hw\n                -low_power 0\n                -global_quality:v "\$HARDWARE_QP"\n                -preset:v medium\n                -pix_fmt nv12\n            \)\n            ;;'''
legacy_block_replacement = '''        intel-legacy)
            ACTIVE_ENCODER="Intel Skylake Legacy Quick Sync"
            FFMPEG_COMMAND=("${LEGACY_INTEL_FFMPEG_COMMAND[@]}")
            if [[ "$HARDWARE_QP_EXPLICIT" == "yes" ]]; then
                legacy_intel_set_plan_args manual
            else
                legacy_intel_set_plan_args safe
            fi
            ;;'''
regex_once(legacy_block_pattern, legacy_block_replacement)

replace_once(
    '    analyze_video "$input_file" || return 0\n'
    '    build_file_video_filter\n',
    '    analyze_video "$input_file" || return 0\n'
    '    if [[ "$ACTIVE_MODE" == "hardware" && "$HW_TYPE" == "intel-legacy" ]]; then\n'
    '        configure_legacy_intel_file "$input_file"\n'
    '    fi\n'
    '    build_file_video_filter\n',
)

PATH.write_text(text, encoding="utf-8")
