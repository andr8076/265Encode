#!/usr/bin/env bash

# 265Encode 3.0.0.
# Hardware HEVC encoding is capability-proven and hardware-only in AUTO.
# Protocol 2 exposes semantic requirements, sealed plans, fingerprints,
# predictions, preservation, and validated atomic execution to dependent tools.
# The interactive and command-line batch encoder remains independently usable.

set -o pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="3.0.0"
LATEST_MACHINE_INTERFACE_VERSION="2"
COMMON_EXTENSIONS=(mp4 mkv mov avi webm m4v ts mts m2ts wmv flv)
HARDWARE_PROBE_SIZE="256x256"
LEGACY_INTEL_HELPER_URL="https://raw.githubusercontent.com/andr8076/265Encode/main/tools/legacy-intel.sh"
LEGACY_INTEL_HELPER_SHA256="cc6138e22f2fe22834e99ace011d8ae1fa8a021e7f5e1cbb281596f514756c38"
LEGACY_INTEL_CALIBRATOR_URL="https://raw.githubusercontent.com/andr8076/265Encode/main/tools/legacy-intel-calibration.py"
LEGACY_INTEL_CALIBRATOR_SHA256="f81b7bfdd5af9ba4edce0c58baee1b7469da4445381bc92317d5c55c8333f1d8"
LEGACY_INTEL_DEVICE_ID=""
LEGACY_INTEL_ADDON_LOADED="no"
LEGACY_INTEL_FFMPEG_COMMAND=()
LEGACY_INTEL_CALIBRATION="${ENCODE265_INTEL_LEGACY_CALIBRATION:-1}"
LEGACY_INTEL_CALIBRATOR=""
LEGACY_INTEL_QUALITY_RUNTIME=""
LEGACY_INTEL_PLAN_NAME="safe"

# Values left empty here are either requested interactively or filled with
# command-line defaults after argument parsing.
INTERACTIVE_MODE=""
INPUT_PATH=""
MODE=""
RECURSIVE=""
USE_ALL_EXTENSIONS=""
SKIP_HEVC=""
OVERWRITE_MODE=""
START_CONFIRM=""
DRY_RUN="no"
LIST_HARDWARE_ONLY="no"
DEBUG_HARDWARE="no"
LEGACY_INTEL_AUTO="${ENCODE265_INTEL_LEGACY_AUTO:-1}"
SOFTWARE_CRF="20"
SOFTWARE_PRESET="slow"
HARDWARE_QP="24"
HARDWARE_QP_EXPLICIT="no"
AUDIO_MODE="aac"
AUDIO_BITRATE="192k"
OUTPUT_EXTENSION="mp4"
VAAPI_DEVICE_OVERRIDE=""
ALLOWED_EXTENSIONS=()
FILES=()

usage() {
    cat <<EOF_USAGE
Usage:
  $SCRIPT_NAME
  $SCRIPT_NAME [options] FILE_OR_FOLDER
  $SCRIPT_NAME [options] --input FILE_OR_FOLDER

With no arguments, the script uses the original interactive menus and selects
only a capability-proven hardware HEVC encoder. Software encoding always
requires an explicit --software request.
With command-line arguments, it runs non-interactively unless --interactive
or --confirm is supplied.

Input and traversal:
  -i, --input PATH          Video file or folder to process
  -r, --recursive          Search folders recursively
      --no-recursive       Search only the selected folder
  -e, --extensions LIST    Extensions separated by commas or spaces
      --common-extensions  Use the built-in common video extensions
      --skip-hevc          Skip input already encoded as H.265/HEVC
      --process-hevc       Allow H.265/HEVC input to be re-encoded

Encoding:
  -m, --mode MODE          auto, software, or hardware
      --auto               Automatically select a working hardware encoder
      --software           Explicitly allow libx265 CPU encoding
      --hardware           Require hardware HEVC encoding
      --crf NUMBER         libx265 CRF, default: 20
      --preset NAME        libx265 preset, default: slow
      --qp NUMBER          Manual hardware QP, default: 24
                           (disables legacy Intel auto-calibration)
      --vaapi-device PATH  Force a VA-API render node, for example
                           /dev/dri/renderD128

Audio and output:
      --audio-bitrate RATE AAC bitrate, default: 192k
      --copy-audio         Copy the first audio stream instead of AAC encoding
      --aac-audio          Encode the first audio stream as AAC
      --container TYPE     mp4 or mkv, default: mp4
      --overwrite          Replace an existing output file
      --skip-existing      Skip an existing output file; CLI default

Operation:
      --interactive        Use prompts while honoring supplied options
      --confirm            Ask before starting in command-line mode
  -y, --yes                Do not ask for start confirmation
      --dry-run            Show FFmpeg commands without running them
      --list-hardware      Detect and display the available HEVC path
      --debug-hardware     Show hardware probe commands and full errors
      --legacy-calibration Enable bounded P530 content calibration (default)
      --no-legacy-calibration
                           Use the verified safe P530 preset without sampling
      --no-legacy-intel    Disable optional legacy Intel fallback for this run

Dependency interface:
      --machine-probe      Print versioned encoder capability JSON and exit
      --interface-version Print the newest machine-interface version and exit
      --machine-negotiate VERSIONS
                           Select the newest supported version
      --machine-evaluate REQUIREMENTS.json --plan-json PLAN.json
      --machine-plan REQUIREMENTS.json --plan-json PLAN.json
                           Evaluate protocol-2 requirements and seal a plan
      --execute-plan PLAN.json --result-json RESULT.json
                           Revalidate fingerprints and execute the sealed plan
  -h, --help               Show this help
      --version            Show the script version

Command-line defaults:
  mode=auto (hardware only), recursive=no, common extensions, process HEVC, AAC 192k,
  container=mp4, and skip existing output files.

Examples:
  $SCRIPT_NAME --hardware --skip-hevc "movie.mkv"

  $SCRIPT_NAME --hardware --recursive --skip-hevc --container mkv "/path/to/videos"

  $SCRIPT_NAME --software --crf 18 --preset slow --copy-audio "movie.mkv"

  $SCRIPT_NAME --interactive --input "/path/to/videos" --hardware
EOF_USAGE
}

error() {
    echo "Error: $*" >&2
}

require_value() {
    local option="$1"
    local value="${2-}"

    if [[ -z "$value" ]]; then
        error "$option requires a value."
        exit 2
    fi
}

is_integer_in_range() {
    local value="$1"
    local minimum="$2"
    local maximum="$3"

    [[ "$value" =~ ^[0-9]+$ ]] &&
        (( value >= minimum && value <= maximum ))
}

parse_extension_list() {
    local extension_text="$1"
    local item

    extension_text="${extension_text//,/ }"
    read -r -a ALLOWED_EXTENSIONS <<< "$extension_text"

    if [[ ${#ALLOWED_EXTENSIONS[@]} -eq 0 ]]; then
        error "No extensions were provided."
        exit 2
    fi

    for item in "${!ALLOWED_EXTENSIONS[@]}"; do
        ALLOWED_EXTENSIONS[$item]="${ALLOWED_EXTENSIONS[$item]#.}"
        ALLOWED_EXTENSIONS[$item]="${ALLOWED_EXTENSIONS[$item],,}"
    done

    USE_ALL_EXTENSIONS="no"
}

parse_arguments() {
    local original_arg_count="$#"

    if (( original_arg_count == 0 )); then
        INTERACTIVE_MODE="yes"
        return
    fi

    INTERACTIVE_MODE="no"

    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --version)
                echo "$SCRIPT_NAME $SCRIPT_VERSION"
                exit 0
                ;;
            -i|--input)
                require_value "$1" "${2-}"
                INPUT_PATH="$2"
                shift 2
                ;;
            -r|--recursive)
                RECURSIVE="yes"
                shift
                ;;
            --no-recursive)
                RECURSIVE="no"
                shift
                ;;
            -e|--extensions)
                require_value "$1" "${2-}"
                parse_extension_list "$2"
                shift 2
                ;;
            --common-extensions)
                USE_ALL_EXTENSIONS="yes"
                ALLOWED_EXTENSIONS=()
                shift
                ;;
            --skip-hevc)
                SKIP_HEVC="yes"
                shift
                ;;
            --process-hevc)
                SKIP_HEVC="no"
                shift
                ;;
            -m|--mode)
                require_value "$1" "${2-}"
                MODE="${2,,}"
                shift 2
                ;;
            --auto)
                MODE="auto"
                shift
                ;;
            --software)
                MODE="software"
                shift
                ;;
            --hardware)
                MODE="hardware"
                shift
                ;;
            --crf)
                require_value "$1" "${2-}"
                SOFTWARE_CRF="$2"
                shift 2
                ;;
            --preset)
                require_value "$1" "${2-}"
                SOFTWARE_PRESET="$2"
                shift 2
                ;;
            --qp)
                require_value "$1" "${2-}"
                HARDWARE_QP="$2"
                HARDWARE_QP_EXPLICIT="yes"
                shift 2
                ;;
            --vaapi-device)
                require_value "$1" "${2-}"
                VAAPI_DEVICE_OVERRIDE="$2"
                shift 2
                ;;
            --audio-bitrate)
                require_value "$1" "${2-}"
                AUDIO_BITRATE="$2"
                shift 2
                ;;
            --copy-audio)
                AUDIO_MODE="copy"
                shift
                ;;
            --aac-audio)
                AUDIO_MODE="aac"
                shift
                ;;
            --container)
                require_value "$1" "${2-}"
                OUTPUT_EXTENSION="${2,,}"
                shift 2
                ;;
            --overwrite)
                OVERWRITE_MODE="yes"
                shift
                ;;
            --skip-existing)
                OVERWRITE_MODE="no"
                shift
                ;;
            --interactive)
                INTERACTIVE_MODE="yes"
                shift
                ;;
            --confirm)
                START_CONFIRM="yes"
                shift
                ;;
            -y|--yes)
                START_CONFIRM="no"
                shift
                ;;
            --dry-run)
                DRY_RUN="yes"
                shift
                ;;
            --list-hardware)
                LIST_HARDWARE_ONLY="yes"
                shift
                ;;
            --debug-hardware)
                DEBUG_HARDWARE="yes"
                shift
                ;;
            --legacy-calibration)
                LEGACY_INTEL_CALIBRATION=1
                shift
                ;;
            --no-legacy-calibration)
                LEGACY_INTEL_CALIBRATION=0
                shift
                ;;
            --no-legacy-intel)
                LEGACY_INTEL_AUTO=0
                shift
                ;;
            --)
                shift
                while (( $# > 0 )); do
                    if [[ -n "$INPUT_PATH" ]]; then
                        error "Only one input file or folder may be specified."
                        exit 2
                    fi
                    INPUT_PATH="$1"
                    shift
                done
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run '$SCRIPT_NAME --help' for usage." >&2
                exit 2
                ;;
            *)
                if [[ -n "$INPUT_PATH" ]]; then
                    error "Only one input file or folder may be specified."
                    exit 2
                fi
                INPUT_PATH="$1"
                shift
                ;;
        esac
    done
}

validate_options() {
    case "$MODE" in
        ""|auto|software|hardware) ;;
        *)
            error "Invalid mode '$MODE'. Use auto, software, or hardware."
            exit 2
            ;;
    esac

    if ! is_integer_in_range "$SOFTWARE_CRF" 0 51; then
        error "--crf must be an integer from 0 to 51."
        exit 2
    fi

    if ! is_integer_in_range "$HARDWARE_QP" 0 51; then
        error "--qp must be an integer from 0 to 51."
        exit 2
    fi

    case "$OUTPUT_EXTENSION" in
        mp4|mkv) ;;
        *)
            error "--container must be mp4 or mkv."
            exit 2
            ;;
    esac

    if [[ -n "$VAAPI_DEVICE_OVERRIDE" && ! -e "$VAAPI_DEVICE_OVERRIDE" ]]; then
        error "VA-API device does not exist: $VAAPI_DEVICE_OVERRIDE"
        exit 2
    fi
}

check_dependencies() {
    local tool

    for tool in ffmpeg ffprobe; do
        if ! command -v "$tool" &>/dev/null; then
            error "$tool is not installed. Please install it to continue."
            exit 1
        fi
    done
}

debug_log() {
    if [[ "$DEBUG_HARDWARE" == "yes" ]]; then
        printf '[hardware debug] %s\n' "$*" >&2
    fi
}

debug_print_command() {
    local argument

    [[ "$DEBUG_HARDWARE" == "yes" ]] || return 0

    printf '[hardware debug] command:' >&2
    for argument in "$@"; do
        printf ' %q' "$argument" >&2
    done
    printf '\n' >&2
}

legacy_intel_hash_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "$file" | awk '{print $1}'
    else
        return 1
    fi
}

legacy_intel_download() {
    local url="$1" output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --retry 2 --connect-timeout 15 --output "$output" "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --tries=3 -O "$output" "$url" 2>/dev/null
    else
        return 1
    fi
}

legacy_intel_host_present() {
    local device vendor device_id driver
    case ${LEGACY_INTEL_AUTO:-1} in 0|false|FALSE|no|NO|off|OFF) return 1 ;; esac
    [[ $(uname -s 2>/dev/null || true) == Linux && $(uname -m 2>/dev/null || true) == x86_64 ]] || return 1
    for device in /sys/class/drm/renderD*/device; do
        [[ -r "$device/vendor" && -r "$device/device" ]] || continue
        read -r vendor < "$device/vendor" || continue
        read -r device_id < "$device/device" || continue
        [[ ${vendor,,} == 0x8086 ]] || continue
        driver=$(basename "$(readlink -f "$device/driver" 2>/dev/null || true)")
        [[ "$driver" == i915 ]] || continue
        case ${device_id,,} in
            0x1902|0x1906|0x190a|0x190b|0x190e|0x1912|0x1913|0x1915|0x1916|0x1917|0x191a|0x191b|0x191d|0x191e|0x1921|0x1923|0x1926|0x1927|0x192a|0x192b|0x192d|0x1932|0x193a|0x193b|0x193d)
                LEGACY_INTEL_DEVICE_ID="${device_id,,}"; return 0 ;;
        esac
    done
    return 1
}

load_legacy_intel_addon() {
    local cache helper tmp actual
    [[ "$LEGACY_INTEL_ADDON_LOADED" == "yes" ]] && return 0
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/265Encode/intel-legacy-addon"
    helper="$cache/legacy-intel.sh"
    mkdir -p "$cache" || return 1
    if [[ -r "$helper" ]]; then
        actual=$(legacy_intel_hash_file "$helper" 2>/dev/null || true)
    fi
    if [[ ${actual:-} != "$LEGACY_INTEL_HELPER_SHA256" ]]; then
        tmp="$helper.download.$$"
        debug_log "Legacy Intel Skylake hardware detected (${LEGACY_INTEL_DEVICE_ID}); downloading optional 265Encode compatibility helper."
        legacy_intel_download "$LEGACY_INTEL_HELPER_URL" "$tmp" || { rm -f "$tmp"; return 1; }
        actual=$(legacy_intel_hash_file "$tmp" 2>/dev/null || true)
        [[ $actual == "$LEGACY_INTEL_HELPER_SHA256" ]] || { rm -f "$tmp"; return 1; }
        mv -f "$tmp" "$helper" || return 1
    fi
    # shellcheck source=/dev/null
    source "$helper" || return 1
    declare -F encode265_legacy_probe >/dev/null 2>&1 || return 1
    declare -F encode265_legacy_command >/dev/null 2>&1 || return 1
    LEGACY_INTEL_ADDON_LOADED="yes"
}

try_legacy_intel_hw() {
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
        matched)
            VIDEO_ENCODER_ARGS=(
                -c:v hevc_qsv -load_plugin hevc_hw -low_power 0
                -q:v 18
                -b_qfactor 1 -b_qoffset 2
                -preset:v veryslow -pix_fmt nv12
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
        compact|efficient|matched|balanced|safe) ;;
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

run_hardware_probe() {
    local label="$1"
    shift

    local output
    local status
    local command=("$@")

    debug_log "$label"
    debug_print_command "${command[@]}"

    # Capture FFmpeg's diagnostics while keeping normal probe output quiet.
    output="$("${command[@]}" </dev/null 2>&1 >/dev/null)"
    status=$?

    if [[ "$DEBUG_HARDWARE" == "yes" ]]; then
        if [[ -n "$output" ]]; then
            while IFS= read -r line; do
                printf '[hardware debug]   %s\n' "$line" >&2
            done <<< "$output"
        fi

        if (( status == 0 )); then
            debug_log "result: success"
        else
            debug_log "result: failed (exit code $status)"
        fi
    fi

    return "$status"
}

encoder_available() {
    local encoder="$1"

    if ffmpeg -hide_banner -encoders 2>/dev/null |
        awk '{print $2}' |
        grep -Fxq "$encoder"; then
        debug_log "FFmpeg lists encoder: $encoder"
        return 0
    fi

    debug_log "FFmpeg does not list encoder: $encoder"
    return 1
}

validate_hardware_probe_output() {
    local output="$1" codec
    codec=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name \
        -of csv=p=0 "$output" 2>/dev/null | head -n1)
    [[ $codec == hevc ]] || {
        debug_log "Probe output codec was ${codec:-unreadable}, not HEVC."
        return 1
    }
    ffmpeg -hide_banner -loglevel error -xerror -nostdin -i "$output" \
        -map '0:V:0' -f null - >/dev/null 2>&1 || {
        debug_log "Probe output failed decode validation."
        return 1
    }
}

test_simple_encoder() {
    local encoder="$1" pixel_format="$2" work output status=1
    work=$(mktemp -d "${TMPDIR:-/tmp}/265encode-probe.XXXXXX") || return 1
    output="$work/probe.mkv"
    local command=(
        ffmpeg -hide_banner -loglevel error -y
        -f lavfi -i "color=black:size=${HARDWARE_PROBE_SIZE}:rate=1"
        -frames:v 1
        -c:v "$encoder"
        -pix_fmt "$pixel_format"
        "$output"
    )

    if run_hardware_probe "Testing $encoder with $pixel_format" "${command[@]}" &&
       validate_hardware_probe_output "$output"; then
        status=0
    fi
    rm -rf -- "$work"
    return "$status"
}

test_vaapi_device() {
    local device="$1" upload_format="$2" work output status=1
    work=$(mktemp -d "${TMPDIR:-/tmp}/265encode-probe.XXXXXX") || return 1
    output="$work/probe.mkv"
    local command=(
        ffmpeg -hide_banner -loglevel error -y
        -init_hw_device "vaapi=va:${device}"
        -filter_hw_device va
        -f lavfi -i "color=black:size=${HARDWARE_PROBE_SIZE}:rate=1"
        -frames:v 1
        -vf "format=${upload_format},hwupload,scale_vaapi=w=${HARDWARE_PROBE_SIZE%x*}:h=${HARDWARE_PROBE_SIZE#*x}:format=${upload_format}:mode=hq"
        -c:v hevc_vaapi
        -qp 30
        "$output"
    )

    # Do not force Main or Main10 here. The VA-API encoder chooses the profile
    # from nv12 or p010le. Forcing a profile can create false probe failures on
    # otherwise working Mesa/VA-API combinations.
    if run_hardware_probe \
        "Testing VA-API device $device with upload format $upload_format" \
        "${command[@]}" && validate_hardware_probe_output "$output"; then
        status=0
    fi
    rm -rf -- "$work"
    return "$status"
}

show_vaapi_environment() {
    local device
    local devices=()

    [[ "$DEBUG_HARDWARE" == "yes" ]] || return 0

    debug_log "FFmpeg: $(ffmpeg -version 2>/dev/null | head -n 1)"
    debug_log "User: $(id 2>/dev/null)"
    debug_log "LIBVA_DRIVER_NAME=${LIBVA_DRIVER_NAME-<unset>}"

    shopt -s nullglob
    devices=(/dev/dri/renderD*)
    shopt -u nullglob

    if [[ ${#devices[@]} -eq 0 ]]; then
        debug_log "No /dev/dri/renderD* devices were found."
        return 0
    fi

    for device in "${devices[@]}"; do
        debug_log "Render device: $(ls -l "$device" 2>/dev/null || printf '%s' "$device")"
        if [[ -r "$device" && -w "$device" ]]; then
            debug_log "Current user has read/write access to $device"
        else
            debug_log "Current user does not have read/write access to $device"
        fi
    done
}

configure_vaapi() {
    local device
    local devices=()

    VAAPI_DEVICE=""
    VAAPI_UPLOAD_FORMAT=""
    VAAPI_PROFILE=""
    VAAPI_BIT_DEPTH=""

    show_vaapi_environment

    if ! encoder_available "hevc_vaapi"; then
        debug_log "VA-API cannot be used because hevc_vaapi is absent from FFmpeg."
        return 1
    fi

    if [[ -n "$VAAPI_DEVICE_OVERRIDE" ]]; then
        devices=("$VAAPI_DEVICE_OVERRIDE")
        debug_log "Using forced VA-API device: $VAAPI_DEVICE_OVERRIDE"
    else
        shopt -s nullglob
        devices=(/dev/dri/renderD*)
        shopt -u nullglob
    fi

    if [[ ${#devices[@]} -eq 0 ]]; then
        debug_log "No VA-API render nodes are available."
        return 1
    fi

    # Prefer 10-bit Main10 and fall back to 8-bit Main.
    for device in "${devices[@]}"; do
        if test_vaapi_device "$device" "p010le"; then
            VAAPI_DEVICE="$device"
            VAAPI_UPLOAD_FORMAT="p010le"
            VAAPI_PROFILE="main10"
            VAAPI_BIT_DEPTH="10-bit"
            debug_log "Selected VA-API device $device in 10-bit mode."
            return 0
        fi
    done

    for device in "${devices[@]}"; do
        if test_vaapi_device "$device" "nv12"; then
            VAAPI_DEVICE="$device"
            VAAPI_UPLOAD_FORMAT="nv12"
            VAAPI_PROFILE="main"
            VAAPI_BIT_DEPTH="8-bit"
            debug_log "Selected VA-API device $device in 8-bit mode."
            return 0
        fi
    done

    debug_log "All VA-API HEVC probes failed."
    return 1
}

json_string() {
    local value="${1-}"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '"%s"' "$value"
}

machine_probe_encoder() {
    local encoder="$1"
    MACHINE_PROBE_ADVERTISED=false
    MACHINE_PROBE_USABLE=false
    MACHINE_PROBE_DETAIL=""

    if encoder_available "$encoder"; then
        MACHINE_PROBE_ADVERTISED=true
    fi

    case "$encoder" in
        hevc_vaapi)
            if configure_vaapi; then
                MACHINE_PROBE_USABLE=true
                MACHINE_PROBE_DETAIL="${VAAPI_DEVICE}, ${VAAPI_BIT_DEPTH}"
            fi
            ;;
        hevc_nvenc)
            if [[ "$MACHINE_PROBE_ADVERTISED" == true ]] &&
               test_simple_encoder hevc_nvenc p010le; then
                MACHINE_PROBE_USABLE=true
                MACHINE_PROBE_DETAIL="NVIDIA NVENC"
            fi
            ;;
        hevc_qsv)
            if [[ "$MACHINE_PROBE_ADVERTISED" == true ]] &&
               test_simple_encoder hevc_qsv p010le; then
                MACHINE_PROBE_USABLE=true
                MACHINE_PROBE_DETAIL="Intel Quick Sync"
            fi
            ;;
        hevc_videotoolbox)
            if [[ "$MACHINE_PROBE_ADVERTISED" == true ]] &&
               test_simple_encoder hevc_videotoolbox yuv420p10le; then
                MACHINE_PROBE_USABLE=true
                MACHINE_PROBE_DETAIL="Apple VideoToolbox"
            fi
            ;;
        libx265)
            if [[ "$MACHINE_PROBE_ADVERTISED" == true ]] &&
               test_simple_encoder libx265 yuv420p10le; then
                MACHINE_PROBE_USABLE=true
                MACHINE_PROBE_DETAIL="x265 software encoder"
            fi
            ;;
    esac
}

machine_encoder_json() {
    local name="$1" class="$2" advertised="$3" usable="$4" detail="$5"
    printf '{"name":%s,"class":%s,"auto_eligible":%s,"advertised":%s,"usable":%s,"detail":%s}' \
        "$(json_string "$name")" "$(json_string "$class")" \
        "$([[ $class == hardware ]] && printf true || printf false)" \
        "$advertised" "$usable" "$(json_string "$detail")"
}

show_machine_capabilities() {
    local ffmpeg_version auto_encoder="" first=true encoder class record
    local -a records=()

    ffmpeg_version=$(ffmpeg -hide_banner -version 2>/dev/null | head -n 1)
    for encoder in hevc_vaapi hevc_nvenc hevc_videotoolbox hevc_qsv libx265; do
        machine_probe_encoder "$encoder"
        class=hardware
        [[ $encoder == libx265 ]] && class=software
        records+=("$(machine_encoder_json "$encoder" "$class" "$MACHINE_PROBE_ADVERTISED" \
            "$MACHINE_PROBE_USABLE" "$MACHINE_PROBE_DETAIL")")
        if [[ -z $auto_encoder && $class == hardware && $MACHINE_PROBE_USABLE == true ]]; then
            auto_encoder=$encoder
        fi
    done

    printf '{"schema":"encode265.capabilities","protocol_version":2,'
    printf '"tool":{"name":"265Encode","version":%s},' "$(json_string "$SCRIPT_VERSION")"
    printf '"supported_protocol_versions":[2],'
    printf '"codec":"hevc","auto_policy":"hardware_only","ffmpeg":%s,' "$(json_string "$ffmpeg_version")"
    printf '"features":{"exact_output":true,"atomic_result":true,"preserve_all":true,"full_decode_validation":true,"semantic_planning":true,"opaque_plan_id":true,"fingerprint_invalidation":true,"sampled_predictions":true,"semantic_requested_encoder":true,"semantic_quality_off":true,"semantic_scaling":true,"semantic_denoise":true,"semantic_audio_optimize":true,"legacy_intel_protocol2":false},'
    if [[ -n $auto_encoder ]]; then
        printf '"auto_encoder":%s,' "$(json_string "$auto_encoder")"
    else
        printf '"auto_encoder":null,'
    fi
    printf '"encoders":['
    for record in "${records[@]}"; do
        [[ $first == true ]] || printf ','
        first=false
        printf '%s' "$record"
    done
    printf ']}\n'
}

detect_hw() {
    HW_TYPE="none"
    HW_DETAIL=""

    # VA-API is the normal AMD path on Linux. Test it first because FFmpeg can
    # list encoders for hardware that is not actually present or usable.
    if configure_vaapi; then
        HW_TYPE="vaapi"
        HW_DETAIL="${VAAPI_DEVICE}, ${VAAPI_BIT_DEPTH} HEVC"
    elif encoder_available "hevc_nvenc" && test_simple_encoder "hevc_nvenc" "p010le"; then
        HW_TYPE="nvidia"
        HW_DETAIL="NVIDIA NVENC"
    elif encoder_available "hevc_videotoolbox" && test_simple_encoder "hevc_videotoolbox" "yuv420p10le"; then
        HW_TYPE="apple"
        HW_DETAIL="Apple VideoToolbox"
    elif encoder_available "hevc_qsv" && test_simple_encoder "hevc_qsv" "p010le"; then
        HW_TYPE="intel"
        HW_DETAIL="Intel Quick Sync"
    elif try_legacy_intel_hw; then
        HW_TYPE="intel-legacy"
        HW_DETAIL="Intel Skylake legacy Media SDK HEVC (${LEGACY_INTEL_DEVICE_ID})"
    fi
}

show_hardware() {
    detect_hw

    if [[ "$HW_TYPE" == "none" ]]; then
        echo "Hardware HEVC encoding: unavailable"
        if [[ "$DEBUG_HARDWARE" != "yes" ]]; then
            echo "Run with --debug-hardware to see the failed probe details."
        fi
        return 1
    fi

    echo "Hardware HEVC encoding: available"
    echo "Type:   $HW_TYPE"
    echo "Detail: $HW_DETAIL"
}

is_allowed_extension() {
    local file="$1"
    local ext="${file##*.}"
    local allowed

    ext="${ext,,}"

    if [[ "$USE_ALL_EXTENSIONS" == "yes" ]]; then
        for allowed in "${COMMON_EXTENSIONS[@]}"; do
            [[ "$ext" == "$allowed" ]] && return 0
        done
        return 1
    fi

    for allowed in "${ALLOWED_EXTENSIONS[@]}"; do
        [[ "$ext" == "$allowed" ]] && return 0
    done

    return 1
}

prompt_yes_no() {
    local prompt="$1"
    local default_answer="$2"
    local answer

    while true; do
        read -r -p "$prompt" answer
        answer="${answer,,}"

        if [[ -z "$answer" ]]; then
            answer="$default_answer"
        fi

        case "$answer" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo "Please enter y or n." ;;
        esac
    done
}

collect_interactive_options() {
    local ext_choice
    local ext_input
    local mode_choice

    echo "--- H.265 Batch Encoder ---"
    echo

    if [[ -z "$INPUT_PATH" ]]; then
        read -r -p "Enter path to a video file or folder: " INPUT_PATH
    fi

    INPUT_PATH="${INPUT_PATH/#\~/$HOME}"

    if [[ ! -e "$INPUT_PATH" ]]; then
        error "Path does not exist: $INPUT_PATH"
        exit 1
    fi

    if [[ -z "$USE_ALL_EXTENSIONS" ]]; then
        echo
        echo "--- Extension Filter ---"
        echo "1) Use common video extensions"
        echo "2) Enter specific extensions"
        read -r -p "Choose 1 or 2: " ext_choice

        if [[ "$ext_choice" == "2" ]]; then
            read -r -p "Enter extensions separated by spaces, example: mp4 mkv mov: " ext_input
            parse_extension_list "$ext_input"
        else
            USE_ALL_EXTENSIONS="yes"
        fi
    fi

    if [[ -z "$SKIP_HEVC" ]]; then
        echo
        if prompt_yes_no "Skip files already encoded as H.265/HEVC? (y/n): " "n"; then
            SKIP_HEVC="yes"
        else
            SKIP_HEVC="no"
        fi
    fi

    detect_hw

    if [[ -z "$MODE" ]]; then
        echo
        echo "--- Encoding Mode ---"
        case "$HW_TYPE" in
            nvidia) echo "1) AUTO hardware - NVIDIA NVENC" ;;
            apple)  echo "1) AUTO hardware - Apple VideoToolbox" ;;
            intel)  echo "1) AUTO hardware - Intel QSV" ;;
            intel-legacy) echo "1) AUTO hardware - Intel Skylake Legacy QSV" ;;
            vaapi)
                echo "1) AUTO hardware - AMD/Linux VA-API"
                echo "   Device: $VAAPI_DEVICE"
                echo "   Mode:   ${VAAPI_BIT_DEPTH} HEVC"
                ;;
            *) echo "1) AUTO hardware - unavailable on this machine" ;;
        esac
        echo "2) Manual software - libx265"

        read -r -p "Select mode [1]: " mode_choice
        if [[ "$mode_choice" == "2" ]]; then
            MODE="software"
        else
            MODE="auto"
        fi
    fi

    if [[ -d "$INPUT_PATH" && -z "$RECURSIVE" ]]; then
        echo
        if prompt_yes_no "Search subfolders too? (y/n): " "n"; then
            RECURSIVE="yes"
        else
            RECURSIVE="no"
        fi
    fi

    [[ -n "$RECURSIVE" ]] || RECURSIVE="no"
    [[ -n "$OVERWRITE_MODE" ]] || OVERWRITE_MODE="ask"
    [[ -n "$START_CONFIRM" ]] || START_CONFIRM="yes"
}

apply_cli_defaults() {
    INPUT_PATH="${INPUT_PATH/#\~/$HOME}"
    [[ -n "$MODE" ]] || MODE="auto"
    [[ -n "$RECURSIVE" ]] || RECURSIVE="no"
    [[ -n "$USE_ALL_EXTENSIONS" ]] || USE_ALL_EXTENSIONS="yes"
    [[ -n "$SKIP_HEVC" ]] || SKIP_HEVC="no"
    [[ -n "$OVERWRITE_MODE" ]] || OVERWRITE_MODE="no"
    [[ -n "$START_CONFIRM" ]] || START_CONFIRM="no"
}

configure_encoder() {
    local selected_mode="$MODE"

    FFMPEG_COMMAND=(ffmpeg)
    FFMPEG_GLOBAL_ARGS=()
    VIDEO_FILTER_ARGS=()
    VIDEO_ENCODER_ARGS=()

    if [[ "$AUDIO_MODE" == "copy" ]]; then
        AUDIO_ARGS=(-c:a copy)
    else
        AUDIO_ARGS=(-c:a aac -b:a "$AUDIO_BITRATE" -ar 48000)
    fi

    # Explicit software mode never probes or downloads optional hardware support.
    if [[ "$selected_mode" == "software" ]]; then
        ACTIVE_MODE="software"
        ACTIVE_ENCODER="libx265"
        VIDEO_ENCODER_ARGS=(
            -c:v libx265
            -crf "$SOFTWARE_CRF"
            -preset "$SOFTWARE_PRESET"
            -pix_fmt yuv420p10le
        )
        return
    fi

    detect_hw

    if [[ "$selected_mode" == "auto" ]]; then
        selected_mode="hardware"
    fi

    if [[ "$selected_mode" == "hardware" && "$HW_TYPE" == "none" ]]; then
        error "No capability-proven HEVC hardware encoder is available."
        echo "AUTO never selects CPU encoding; use --software to explicitly allow libx265." >&2
        exit 1
    fi

    if [[ "$selected_mode" == "software" ]]; then
        ACTIVE_MODE="software"
        ACTIVE_ENCODER="libx265"
        VIDEO_ENCODER_ARGS=(
            -c:v libx265
            -crf "$SOFTWARE_CRF"
            -preset "$SOFTWARE_PRESET"
            -pix_fmt yuv420p10le
        )
        return
    fi

    ACTIVE_MODE="hardware"

    case "$HW_TYPE" in
        nvidia)
            ACTIVE_ENCODER="NVIDIA NVENC"
            VIDEO_ENCODER_ARGS=(
                -c:v hevc_nvenc
                -rc vbr
                -cq "$HARDWARE_QP"
                -preset slow
                -pix_fmt yuv420p10le
            )
            ;;
        apple)
            ACTIVE_ENCODER="Apple VideoToolbox"
            VIDEO_ENCODER_ARGS=(
                -c:v hevc_videotoolbox
                -q:v 65
                -pix_fmt yuv420p10le
            )
            ;;
        intel)
            ACTIVE_ENCODER="Intel Quick Sync"
            VIDEO_ENCODER_ARGS=(
                -c:v hevc_qsv
                -global_quality "$HARDWARE_QP"
                -preset slow
                -pix_fmt yuv420p10le
            )
            ;;
        intel-legacy)
            ACTIVE_ENCODER="Intel Skylake Legacy Quick Sync"
            FFMPEG_COMMAND=("${LEGACY_INTEL_FFMPEG_COMMAND[@]}")
            if [[ "$HARDWARE_QP_EXPLICIT" == "yes" ]]; then
                legacy_intel_set_plan_args manual
            else
                legacy_intel_set_plan_args safe
            fi
            ;;
        vaapi)
            ACTIVE_ENCODER="AMD/Linux VA-API"
            FFMPEG_GLOBAL_ARGS=(
                -init_hw_device "vaapi=va:${VAAPI_DEVICE}"
                -filter_hw_device va
            )
            # The final per-file filter is built after ffprobe has supplied the
            # stream's initial width, height, and sample aspect ratio.
            VIDEO_FILTER_ARGS=()
            VIDEO_ENCODER_ARGS=(
                -c:v hevc_vaapi
                -rc_mode CQP
                -qp "$HARDWARE_QP"
            )
            ;;
        *)
            error "Internal error: unsupported hardware type '$HW_TYPE'."
            exit 1
            ;;
    esac
}

analyze_video() {
    local input_file="$1"
    local video_info
    local current_codec
    local current_width
    local current_height
    local current_sar

    video_info="$(ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=codec_name,width,height,sample_aspect_ratio \
        -of csv=p=0 \
        "$input_file")"

    IFS=',' read -r current_codec current_width current_height current_sar <<< "$video_info"

    if [[ -z "$current_codec" || ! "$current_width" =~ ^[0-9]+$ ||
          ! "$current_height" =~ ^[0-9]+$ ]]; then
        echo "Skipping: could not read the first video stream."
        return 1
    fi

    case "$current_sar" in
        ""|N/A|0:1|0/1) current_sar="1:1" ;;
    esac

    INPUT_VIDEO_CODEC="$current_codec"
    INPUT_VIDEO_WIDTH="$current_width"
    INPUT_VIDEO_HEIGHT="$current_height"
    INPUT_VIDEO_SAR="$current_sar"

    echo "Codec:      $current_codec"
    echo "Resolution: ${current_width}x${current_height}"
    echo "Pixel SAR:  $current_sar"

    if [[ "$current_codec" == "hevc" ]]; then
        echo "Warning: already H.265/HEVC."
        if [[ "$SKIP_HEVC" == "yes" ]]; then
            echo "Skipping because HEVC skip is enabled."
            return 1
        fi
    fi

    if (( current_height > 1080 )); then
        echo "Warning: resolution is higher than 1080p. Original resolution will be kept."
    fi

    return 0
}

build_file_video_filter() {
    local sar_for_filter

    VIDEO_FILTER_ARGS=()
    VIDEO_OUTPUT_ARGS=()

    if [[ "$ACTIVE_MODE" == "hardware" && "$HW_TYPE" == "vaapi" ]]; then
        # A colon separates filters and their options, so use slash notation
        # for the sample-aspect ratio inside the setsar expression.
        sar_for_filter="${INPUT_VIDEO_SAR/:/\/}"

        VIDEO_FILTER_ARGS=(
            -vf
            "format=${VAAPI_UPLOAD_FORMAT},hwupload,scale_vaapi=w=${INPUT_VIDEO_WIDTH}:h=${INPUT_VIDEO_HEIGHT}:format=${VAAPI_UPLOAD_FORMAT}:mode=hq,setsar=sar=${sar_for_filter}"
        )

        # The graph above already guarantees a fixed output size. Disabling
        # FFmpeg's implicit end-of-graph scaler prevents it from trying to put
        # a software scaler after VA-API hardware frames during reinitialization.
        VIDEO_OUTPUT_ARGS=(-noautoscale)
    fi
}

print_command() {
    local argument
    local first="yes"

    for argument in "$@"; do
        if [[ "$first" == "yes" ]]; then
            first="no"
        else
            printf ' '
        fi
        printf '%q' "$argument"
    done
    printf '\n'
}

validate_completed_output() {
    local source="$1" candidate="$2" codec source_duration output_duration

    [[ -s $candidate ]] || {
        error "Encoding produced no output file."
        return 1
    }
    codec=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name \
        -of csv=p=0 "$candidate" 2>/dev/null | head -n1)
    [[ $codec == hevc ]] || {
        error "Completed output codec was ${codec:-unreadable}, not HEVC."
        return 1
    }

    source_duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 \
        "$source" 2>/dev/null | head -n1)
    output_duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 \
        "$candidate" 2>/dev/null | head -n1)
    if [[ $source_duration =~ ^[0-9]+([.][0-9]+)?$ &&
          $output_duration =~ ^[0-9]+([.][0-9]+)?$ ]] &&
       ! awk -v source="$source_duration" -v output="$output_duration" \
           'BEGIN {delta=source-output; if(delta<0)delta=-delta; exit !(delta<=2)}'; then
        error "Completed output duration differs from the input by more than two seconds."
        return 1
    fi

    ffmpeg -hide_banner -loglevel error -xerror -nostdin -i "$candidate" \
        -map '0:V:0' -map '0:a?' -f null - >/dev/null 2>&1 || {
        error "Completed output failed full video/audio decode validation."
        return 1
    }
}

encode_file() {
    local input_file="$1"
    local output_file="${input_file%.*}_h265.${OUTPUT_EXTENSION}"
    local temporary_output="${input_file%.*}_h265.part.${OUTPUT_EXTENSION}"
    local ffmpeg_status
    local overwrite_answer
    local output_args=()
    local command=()

    VIDEO_OUTPUT_ARGS=()

    echo
    echo "=========================================="
    echo "Processing:"
    echo "$input_file"
    echo "=========================================="

    if [[ -e "$output_file" ]]; then
        case "$OVERWRITE_MODE" in
            yes)
                echo "Overwriting existing output: $output_file"
                ;;
            ask)
                if ! prompt_yes_no "Output exists. Overwrite? (y/n): " "n"; then
                    echo "Skipped."
                    return 0
                fi
                ;;
            *)
                echo "Output exists; skipped: $output_file"
                return 0
                ;;
        esac
    fi

    analyze_video "$input_file" || return 0
    if [[ "$ACTIVE_MODE" == "hardware" && "$HW_TYPE" == "intel-legacy" ]]; then
        configure_legacy_intel_file "$input_file"
    fi
    build_file_video_filter

    if [[ -e "$temporary_output" ]]; then
        echo "Removing stale partial output: $temporary_output"
        if ! rm -f -- "$temporary_output"; then
            error "Could not remove stale partial output: $temporary_output"
            return 1
        fi
    fi

    if [[ "$OUTPUT_EXTENSION" == "mp4" ]]; then
        output_args=(-movflags +faststart)
    fi

    command=(
        "${FFMPEG_COMMAND[@]}"
        -hide_banner
        -y
        "${FFMPEG_GLOBAL_ARGS[@]}"
        -i "$input_file"
        -map 0:v:0
        -map '0:a:0?'
        "${VIDEO_FILTER_ARGS[@]}"
        "${VIDEO_OUTPUT_ARGS[@]}"
        "${VIDEO_ENCODER_ARGS[@]}"
        "${AUDIO_ARGS[@]}"
        "${output_args[@]}"
        "$temporary_output"
    )

    echo
    echo "Encoding with: $ACTIVE_ENCODER"
    if [[ "$ACTIVE_MODE" == "hardware" && "$HW_TYPE" == "vaapi" ]]; then
        echo "VA-API frame lock: ${INPUT_VIDEO_WIDTH}x${INPUT_VIDEO_HEIGHT}, SAR ${INPUT_VIDEO_SAR}"
    fi

    if [[ "$DRY_RUN" == "yes" ]]; then
        print_command "${command[@]}"
        return 0
    fi

    "${command[@]}"
    ffmpeg_status=$?

    if [[ $ffmpeg_status -eq 0 ]]; then
        if ! validate_completed_output "$input_file" "$temporary_output"; then
            rm -f -- "$temporary_output"
            error "Completed output was rejected and removed; the input is unchanged."
            return 1
        fi

        if ! mv -f -- "$temporary_output" "$output_file"; then
            error "Encoding succeeded, but the completed file could not be moved into place."
            echo "Completed temporary file: $temporary_output" >&2
            return 1
        fi

        echo "Done: $output_file"
    else
        echo "Error while encoding: $input_file"
        echo "FFmpeg exit code: $ffmpeg_status"
        if [[ -e "$temporary_output" ]]; then
            echo "Partial output kept as: $temporary_output"
        fi
        return "$ffmpeg_status"
    fi
}

collect_files_from_folder() {
    local folder="$1"
    local recursive="$2"
    local file
    local find_args=()

    FILES=()

    if [[ "$recursive" == "yes" ]]; then
        find_args=("$folder" -type f -print0)
    else
        find_args=("$folder" -maxdepth 1 -type f -print0)
    fi

    while IFS= read -r -d '' file; do
        if is_allowed_extension "$file"; then
            FILES+=("$file")
        fi
    done < <(find "${find_args[@]}" | sort -z)
}

collect_input_files() {
    if [[ -z "$INPUT_PATH" ]]; then
        error "No input was specified."
        echo "Run '$SCRIPT_NAME --help' for usage." >&2
        exit 2
    fi

    if [[ ! -e "$INPUT_PATH" ]]; then
        error "Path does not exist: $INPUT_PATH"
        exit 1
    fi

    if [[ -f "$INPUT_PATH" ]]; then
        if is_allowed_extension "$INPUT_PATH"; then
            FILES=("$INPUT_PATH")
        else
            error "File extension does not match the selected extension filter."
            exit 1
        fi
    elif [[ -d "$INPUT_PATH" ]]; then
        collect_files_from_folder "$INPUT_PATH" "$RECURSIVE"
    else
        error "Input is neither a regular file nor a directory: $INPUT_PATH"
        exit 1
    fi
}

show_plan() {
    local file

    echo
    echo "Encoding plan"
    echo "=========================================="
    echo "Input:       $INPUT_PATH"
    echo "Files:       ${#FILES[@]}"
    echo "Mode:        $ACTIVE_MODE"
    echo "Encoder:     $ACTIVE_ENCODER"
    echo "Container:   $OUTPUT_EXTENSION"
    if [[ "$AUDIO_MODE" == "aac" ]]; then
        echo "Audio:       AAC ${AUDIO_BITRATE}"
    else
        echo "Audio:       Copy first audio stream"
    fi
    echo "Recursive:   $RECURSIVE"
    echo "Skip HEVC:   $SKIP_HEVC"
    echo "Overwrite:   $OVERWRITE_MODE"
    echo "Dry run:     $DRY_RUN"
    echo "=========================================="

    for file in "${FILES[@]}"; do
        echo " - $file"
    done
}

dispatch_dependency_interface() {
    local script_dir planner
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    planner="$script_dir/tools/HEVCPlan.py"

    case "${1-}" in
        --interface-version)
            (( $# == 1 )) || { error "Usage: $SCRIPT_NAME --interface-version"; exit 2; }
            printf '%s\n' "$LATEST_MACHINE_INTERFACE_VERSION"
            exit 0
            ;;
        --machine-probe)
            (( $# == 1 )) || { error "Usage: $SCRIPT_NAME --machine-probe"; exit 2; }
            check_dependencies
            show_machine_capabilities
            exit 0
            ;;
        --machine-negotiate)
            (( $# == 2 )) || {
                error "Usage: $SCRIPT_NAME --machine-negotiate VERSION[,VERSION...]"
                exit 2
            }
            command -v python3 >/dev/null 2>&1 || {
                error "python3 is required for protocol 2."
                exit 1
            }
            exec python3 "$planner" negotiate "$2"
            ;;
        --machine-evaluate|--machine-plan)
            (( $# == 4 )) && [[ "$3" == --plan-json ]] || {
                error "Usage: $SCRIPT_NAME $1 REQUIREMENTS.json --plan-json PLAN.json"
                exit 2
            }
            command -v python3 >/dev/null 2>&1 || {
                error "python3 is required for protocol 2."
                exit 1
            }
            exec python3 "$planner" evaluate "$2" "$4" "$script_dir/265Encode.sh"
            ;;
        --execute-plan)
            (( $# == 4 )) && [[ "$3" == --result-json ]] || {
                error "Usage: $SCRIPT_NAME --execute-plan PLAN.json --result-json RESULT.json"
                exit 2
            }
            command -v python3 >/dev/null 2>&1 || {
                error "python3 is required for protocol 2."
                exit 1
            }
            exec python3 "$planner" execute "$2" "$4" "$script_dir/265Encode.sh"
            ;;
    esac
}

main() {
    local file
    local failures=0

    dispatch_dependency_interface "$@"
    parse_arguments "$@"
    validate_options
    check_dependencies

    if [[ "$LIST_HARDWARE_ONLY" == "yes" ]]; then
        show_hardware
        exit $?
    fi

    if [[ "$INTERACTIVE_MODE" == "yes" ]]; then
        collect_interactive_options
    else
        apply_cli_defaults
    fi

    validate_options
    configure_encoder
    collect_input_files

    if [[ ${#FILES[@]} -eq 0 ]]; then
        echo "No matching video files found."
        exit 0
    fi

    show_plan

    if [[ "$START_CONFIRM" == "yes" ]]; then
        echo
        if ! prompt_yes_no "Start encoding these files? (y/n): " "n"; then
            echo "Cancelled."
            exit 0
        fi
    fi

    for file in "${FILES[@]}"; do
        if ! encode_file "$file"; then
            ((failures++))
        fi
    done

    echo
    if (( failures == 0 )); then
        echo "All done."
        exit 0
    fi

    echo "Finished with $failures failed file(s)."
    exit 1
}

main "$@"
