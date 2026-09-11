#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.0"
MODE="sampled"
TARGET="92"
QUALITY=1
SAMPLE_SECONDS="4"
INTERVAL_SECONDS="300"
MIN_SAMPLES="5"
MAX_SAMPLES="16"
COMPLEXITY_SAMPLES="2"
LOW_PERCENTILE="10"
PERCENTILE_DELTA="4"
SUSTAINED_DELTA="6"
SUSTAINED_SECONDS="1"

usage() {
    cat <<'USAGE'
Usage:
  265Compare.sh [options] ORIGINAL CANDIDATE

Compare two media files including size, container/stream metadata, and video quality.
The default quality policy matches Hardcore Archive completed-output validation.

Options:
  --sampled            VMAF sampled mode (default)
  --full               VMAF full-timeline mode (slow)
  --no-quality         Metadata/size/track comparison only
  --target VMAF        Quality target, default 92
  --version            Show version
  -h, --help           Show this help
USAGE
}

while (($#)); do
    case "$1" in
        --sampled) MODE=sampled; shift ;;
        --full) MODE=full; shift ;;
        --no-quality) QUALITY=0; shift ;;
        --target) [[ $# -ge 2 ]] || { echo "--target requires a value" >&2; exit 2; }; TARGET=$2; shift 2 ;;
        --version) echo "265Compare.sh $VERSION"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) break ;;
    esac
done
[[ $# -eq 2 ]] || { usage >&2; exit 2; }
REFERENCE=$1
CANDIDATE=$2
[[ -f $REFERENCE ]] || { echo "Original not found: $REFERENCE" >&2; exit 2; }
[[ -f $CANDIDATE ]] || { echo "Candidate not found: $CANDIDATE" >&2; exit 2; }
command -v python3 >/dev/null || { echo "Missing dependency: python3" >&2; exit 2; }
command -v ffprobe >/dev/null || { echo "Missing dependency: ffprobe" >&2; exit 2; }

human_report() {
python3 - "ffprobe" "$REFERENCE" "$CANDIDATE" <<'PY'
import json, os, subprocess, sys
ffprobe, ref, cand = sys.argv[1:]

def probe(path):
    p=subprocess.run([ffprobe,'-v','error','-show_format','-show_streams','-of','json',path],capture_output=True,text=True)
    if p.returncode: raise SystemExit(p.stderr.strip() or 'ffprobe failed')
    return json.loads(p.stdout)

def human_bytes(n):
    v=float(n)
    for unit in ('B','KiB','MiB','GiB','TiB'):
        if v < 1024 or unit=='TiB': return f'{v:.2f} {unit}'
        v/=1024

def num(v, default=0.0):
    try: return float(v)
    except: return default

def fps(v):
    try:
        a,b=v.split('/'); b=float(b); return float(a)/b if b else 0
    except: return 0

def tags(s):
    t=s.get('tags') or {}; bits=[]
    if t.get('language'): bits.append(f"lang={t['language']}")
    if t.get('title'): bits.append(f"title={t['title']}")
    d=s.get('disposition') or {}
    if d.get('default'): bits.append('default')
    if d.get('forced'): bits.append('forced')
    if d.get('hearing_impaired'): bits.append('hearing-impaired')
    return ', '.join(bits) if bits else '-'

def br(v):
    x=num(v); return f'{x/1e6:.2f} Mb/s' if x else 'unknown'

def summary(label,path,d):
    fmt=d.get('format') or {}; size=os.path.getsize(path); dur=num(fmt.get('duration'))
    streams=d.get('streams') or []
    counts={k:sum(1 for s in streams if s.get('codec_type')==k) for k in ('video','audio','subtitle','data','attachment')}
    print(f'\n{label}')
    print('─'*72)
    print(f'File:       {path}')
    print(f'Size:       {human_bytes(size)} ({size:,} bytes)')
    print(f'Duration:   {dur:.3f} s')
    print(f'Container:  {fmt.get("format_long_name") or fmt.get("format_name") or "unknown"}')
    print(f'Bitrate:    {br(fmt.get("bit_rate"))}')
    print('Tracks:     ' + ' | '.join(f'{k}={counts[k]}' for k in counts))
    for s in streams:
        typ=s.get('codec_type','unknown'); idx=s.get('index','?'); codec=s.get('codec_name','unknown')
        if typ=='video':
            rate=fps(s.get('avg_frame_rate') or s.get('r_frame_rate') or '0/0')
            extra=f"{s.get('width','?')}x{s.get('height','?')}, {s.get('pix_fmt','?')}, {rate:.3f} fps, {br(s.get('bit_rate'))}, profile={s.get('profile','?')}"
            if (s.get('disposition') or {}).get('attached_pic'): extra += ', attached-pic'
        elif typ=='audio':
            extra=f"{s.get('sample_rate','?')} Hz, {s.get('channels','?')} ch, {s.get('channel_layout','?')}, {br(s.get('bit_rate'))}, profile={s.get('profile','?')}"
        elif typ=='subtitle':
            extra=f"codec={codec}"
        else:
            extra=f"codec={codec}"
        print(f'  #{idx:<2} {typ:<10} {codec:<14} {extra}; {tags(s)}')
    return size,dur,counts

rd,cd=probe(ref),probe(cand)
rs,rdur,rc=summary('ORIGINAL',ref,rd)
cs,cdur,cc=summary('CANDIDATE',cand,cd)
print('\nCOMPARISON')
print('═'*72)
delta=cs-rs
saving=(1-cs/rs)*100 if rs else 0
ratio=(cs/rs) if rs else 0
print(f'Size:       {human_bytes(rs)} -> {human_bytes(cs)}  ({saving:+.2f}% saved; candidate={ratio:.3f}x original)')
print(f'Duration:   {rdur:.3f}s -> {cdur:.3f}s  (delta {cdur-rdur:+.3f}s)')
for k in ('video','audio','subtitle','data','attachment'):
    mark='OK' if rc[k]==cc[k] else 'CHANGED'
    print(f'{k.capitalize():<11}{rc[k]} -> {cc[k]}  [{mark}]')
PY
}

human_report
(( QUALITY )) || exit 0

# The policy helper is shipped beside this script. A standalone copy can fetch it
# from the same project only; no external project dependency is used.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
HELPER_SHA256="5acd2160930a77557b596fa18d49cc63983b734239a67b3c8615849360f401da"
HELPER="$SCRIPT_DIR/tools/265Compare-quality.py"
if [[ ! -f $HELPER ]]; then
    CACHE_BASE=${XDG_CACHE_HOME:-"$HOME/.cache"}/265Encode/compare
    mkdir -p "$CACHE_BASE"
    HELPER="$CACHE_BASE/265Compare-quality.py"
    if [[ ! -s $HELPER ]]; then
        echo "Downloading 265Compare quality policy helper..."
        curl -fL --retry 3 --connect-timeout 15 \
            https://raw.githubusercontent.com/andr8076/265Encode/main/tools/265Compare-quality.py \
            -o "$HELPER.tmp"
        if command -v sha256sum >/dev/null; then helper_actual=$(sha256sum "$HELPER.tmp" | awk '{print $1}'); else helper_actual=$(shasum -a 256 "$HELPER.tmp" | awk '{print $1}'); fi
        [[ ${helper_actual,,} == "$HELPER_SHA256" ]] || { echo "265Compare quality helper checksum verification failed." >&2; rm -f "$HELPER.tmp"; exit 3; }
        mv -f "$HELPER.tmp" "$HELPER"
    fi
fi
if command -v sha256sum >/dev/null; then helper_actual=$(sha256sum "$HELPER" | awk '{print $1}'); else helper_actual=$(shasum -a 256 "$HELPER" | awk '{print $1}'); fi
[[ ${helper_actual,,} == "$HELPER_SHA256" ]] || { echo "265Compare quality helper checksum mismatch: $HELPER" >&2; exit 3; }

select_quality_tools() {
    if [[ -n ${ENCODE265_COMPARE_FFMPEG:-} && -n ${ENCODE265_COMPARE_FFPROBE:-} ]]; then
        QFFMPEG=$ENCODE265_COMPARE_FFMPEG
        QFFPROBE=$ENCODE265_COMPARE_FFPROBE
        return 0
    fi
    if command -v ffmpeg >/dev/null; then
        local system_filters
        system_filters=$(ffmpeg -hide_banner -filters 2>/dev/null || true)
        if grep -Eq '(^|[[:space:]])libvmaf([[:space:]]|$)' <<< "$system_filters"; then
            QFFMPEG=$(command -v ffmpeg)
            QFFPROBE=$(command -v ffprobe)
            return 0
        fi
    fi

    local os arch target cache base pointer asset expected actual archive
    case $(uname -s) in Linux) os=linux ;; Darwin) os=macos ;; *) echo "Unsupported OS for managed VMAF runtime." >&2; return 1 ;; esac
    case $(uname -m) in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=arm64 ;; *) echo "Unsupported architecture for managed VMAF runtime." >&2; return 1 ;; esac
    target="$os-$arch"
    cache=${XDG_CACHE_HOME:-"$HOME/.cache"}/265Encode/quality-runtime/$target
    if [[ ! -x $cache/runtime/bin/ffmpeg || ! -x $cache/runtime/bin/ffprobe ]]; then
        command -v curl >/dev/null || { echo "Missing curl; cannot fetch optional quality runtime." >&2; return 1; }
        command -v tar >/dev/null || { echo "Missing tar; cannot unpack optional quality runtime." >&2; return 1; }
        base="https://github.com/andr8076/265Encode/releases/download/quality-runtime-latest"
        pointer="265encode-quality-runtime-${target}.current"
        mkdir -p "$cache"
        echo "Downloading optional 265Encode VMAF quality runtime..."
        asset=$(curl -fsSL --retry 3 "$base/$pointer") || { echo "Quality runtime is not published for $target." >&2; return 1; }
        asset=${asset//$'\r'/}; asset=${asset//$'\n'/}
        [[ $asset == 265encode-quality-runtime-${target}-*.tar.gz ]] || { echo "Invalid runtime pointer." >&2; return 1; }
        archive="$cache/$asset"
        curl -fL --retry 3 "$base/$asset" -o "$archive.tmp"
        curl -fsSL --retry 3 "$base/$asset.sha256" -o "$archive.sha256.tmp"
        expected=$(awk 'NF {print $1; exit}' "$archive.sha256.tmp")
        if command -v sha256sum >/dev/null; then actual=$(sha256sum "$archive.tmp" | awk '{print $1}'); else actual=$(shasum -a 256 "$archive.tmp" | awk '{print $1}'); fi
        [[ $expected =~ ^[0-9a-fA-F]{64}$ && ${expected,,} == "$actual" ]] || { echo "Quality runtime checksum verification failed." >&2; rm -f "$archive.tmp" "$archive.sha256.tmp"; return 1; }
        rm -rf "$cache/runtime.new"
        mkdir -p "$cache/runtime.new"
        tar -xzf "$archive.tmp" -C "$cache/runtime.new"
        [[ -x $cache/runtime.new/runtime/bin/ffmpeg && -x $cache/runtime.new/runtime/bin/ffprobe ]] || { echo "Quality runtime archive is incomplete." >&2; return 1; }
        rm -rf "$cache/runtime"
        mv "$cache/runtime.new/runtime" "$cache/runtime"
        rm -rf "$cache/runtime.new" "$archive.tmp" "$archive.sha256.tmp"
    fi
    QFFMPEG="$cache/runtime/bin/ffmpeg"
    QFFPROBE="$cache/runtime/bin/ffprobe"
    if [[ $os == linux ]]; then
        export LD_LIBRARY_PATH="$cache/runtime/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
}

select_quality_tools || { echo "Metadata comparison completed, but VMAF quality comparison is unavailable." >&2; exit 3; }
QFILTERS=$("$QFFMPEG" -hide_banner -filters 2>/dev/null || true)
grep -Eq '(^|[[:space:]])libvmaf([[:space:]]|$)' <<< "$QFILTERS" || { echo "Selected FFmpeg does not provide libvmaf." >&2; exit 3; }

DURATION=$($QFFPROBE -v error -select_streams V:0 -show_entries format=duration -of default=nw=1:nk=1 "$REFERENCE" | head -n1)
[[ $DURATION =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Could not determine source duration." >&2; exit 3; }

IFS=' ' read -r CODED_W CODED_H SAR ROTATION < <(python3 - "$QFFPROBE" "$REFERENCE" <<'PY'
import json,subprocess,sys
p=subprocess.run([sys.argv[1],'-v','error','-select_streams','V:0','-show_streams','-of','json',sys.argv[2]],capture_output=True,text=True,check=True)
s=(json.loads(p.stdout).get('streams') or [{}])[0]
rot=0
for sd in s.get('side_data_list') or []:
    if 'rotation' in sd:
        try: rot=int(sd['rotation'])
        except: pass
print(s.get('width',0),s.get('height',0),s.get('sample_aspect_ratio') or '1:1',rot)
PY
)
[[ $CODED_W =~ ^[1-9][0-9]*$ && $CODED_H =~ ^[1-9][0-9]*$ ]] || { echo "Could not determine source display geometry." >&2; exit 3; }
IFS=: read -r SAR_N SAR_D <<< "$SAR"
[[ $SAR_N =~ ^[1-9][0-9]*$ && $SAR_D =~ ^[1-9][0-9]*$ ]] || { SAR_N=1; SAR_D=1; }
ROTATION=$(( (ROTATION % 360 + 360) % 360 ))
DISPLAY_W=$(awk -v w="$CODED_W" -v n="$SAR_N" -v d="$SAR_D" 'BEGIN{v=w*n/d; r=int(v/2+0.5)*2; if(r<2)r=2; printf "%d",r}')
DISPLAY_H=$CODED_H
if (( ROTATION == 90 || ROTATION == 270 )); then tmp=$DISPLAY_W; DISPLAY_W=$DISPLAY_H; DISPLAY_H=$tmp; fi
if (( DISPLAY_W >= DISPLAY_H )); then LONG=$DISPLAY_W; SHORT=$DISPLAY_H; else LONG=$DISPLAY_H; SHORT=$DISPLAY_W; fi
if (( LONG >= 3840 && SHORT >= 2160 )); then MODEL=vmaf_4k_v0.6.1; MODEL_LABEL='4K/1.5H'; else MODEL=vmaf_v0.6.1; MODEL_LABEL='1080p/3H'; fi
THREADS=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
[[ $THREADS =~ ^[1-9][0-9]*$ ]] || THREADS=1
(( THREADS > 8 )) && THREADS=8

TMP=$(mktemp -d "${TMPDIR:-/tmp}/265compare.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
PLAN="$TMP/plan.tsv"
MANIFEST="$TMP/manifest.tsv"
: > "$MANIFEST"
python3 "$HELPER" plan --input "$CANDIDATE" --duration "$DURATION" --mode "$MODE" \
    --sample-seconds "$SAMPLE_SECONDS" --interval-seconds "$INTERVAL_SECONDS" \
    --min-samples "$MIN_SAMPLES" --max-samples "$MAX_SAMPLES" \
    --complexity-samples "$COMPLEXITY_SAMPLES" --ffprobe "$QFFPROBE" > "$PLAN"
[[ -s $PLAN ]] || { echo "VMAF sample plan was empty." >&2; exit 3; }

RATIO="${DISPLAY_W}/${DISPLAY_H}"
NORMALIZE="scale=w='max(2,trunc(iw*if(eq(sar,0),1,sar)/2)*2)':h='max(2,trunc(ih/2)*2)':flags=bicubic:in_range=auto:out_range=tv,setsar=1"
FIT="scale=w='if(gt(a,${RATIO}),${DISPLAY_W},-2)':h='if(gt(a,${RATIO}),-2,${DISPLAY_H})':flags=bicubic:in_range=tv:out_range=tv,pad=${DISPLAY_W}:${DISPLAY_H}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuv420p"

echo
echo "VIDEO QUALITY — Hardcore Archive policy"
echo "════════════════════════════════════════════════════════════════════════"
echo "Mode:       $MODE"
echo "Canvas:     ${DISPLAY_W}x${DISPLAY_H} (source display resolution)"
echo "Model:      $MODEL ($MODEL_LABEL)"
P_FLOOR=$(awk -v t="$TARGET" -v d="$PERCENTILE_DELTA" 'BEGIN{printf "%.3f",t-d}')
S_FLOOR=$(awk -v t="$TARGET" -v d="$SUSTAINED_DELTA" 'BEGIN{printf "%.3f",t-d}')
echo "Target:     VMAF $TARGET | p${LOW_PERCENTILE} floor $P_FLOOR | sustained floor $S_FLOOR for ${SUSTAINED_SECONDS}s"
echo "Samples:    $(wc -l < "$PLAN")"

idx=0
while IFS=$'\t' read -r kind start length; do
    idx=$((idx+1)); log="$TMP/vmaf-$idx.json"
    graph="[0:v:0]settb=AVTB,setpts=PTS-STARTPTS,${NORMALIZE},${FIT}[ref];[1:v:0]settb=AVTB,setpts=PTS-STARTPTS,${NORMALIZE},${FIT}[dist];[dist][ref]libvmaf=model='version=${MODEL}':log_fmt=json:log_path=${log}:n_threads=${THREADS}:n_subsample=1:ts_sync_mode=nearest"
    printf 'Sample %2d/%-2d %-10s at %8.3fs for %.3fs ... ' "$idx" "$(wc -l < "$PLAN")" "$kind" "$start" "$length"
    if "$QFFMPEG" -hide_banner -v error -nostdin -ss "$start" -t "$length" -i "$REFERENCE" -ss "$start" -t "$length" -i "$CANDIDATE" -filter_complex "$graph" -an -f null - >/dev/null 2>&1 && [[ -s $log ]]; then
        printf 'measured\n'; printf '%s\t%s\t%s\t%s\n' "$kind" "$start" "$length" "$log" >> "$MANIFEST"
    else
        printf 'FAILED\n'; echo "VMAF measurement failed; quality result is not trustworthy." >&2; exit 3
    fi
done < "$PLAN"

set +e
RESULT=$(python3 "$HELPER" evaluate --manifest "$MANIFEST" --duration "$DURATION" --threshold "$TARGET" \
    --reference "$REFERENCE" --candidate "$CANDIDATE" --ffprobe "$QFFPROBE" \
    --low-percentile "$LOW_PERCENTILE" --percentile-delta "$PERCENTILE_DELTA" \
    --sustained-delta "$SUSTAINED_DELTA" --sustained-seconds "$SUSTAINED_SECONDS")
RC=$?
set -e
python3 - "$RESULT" "$MODE" "$TARGET" <<'PY'
import json,sys
r=json.loads(sys.argv[1]); mode=sys.argv[2]; target=float(sys.argv[3])
print('\nQUALITY RESULT')
print('═'*72)
print(f"Status:            {r.get('status','error').upper()}")
print(f"Policy:            {r.get('policy','?')}")
print(f"Mean VMAF:         {r.get('mean_vmaf',0):.3f}")
print(f"Worst window mean: {r.get('minimum_window_mean',0):.3f}")
print(f"p{r.get('low_percentile','?')} VMAF:          {r.get('low_percentile_vmaf',0):.3f}  (floor {r.get('low_percentile_floor',0):.3f})")
print(f"Sustained low:     {r.get('longest_sustained_seconds',0):.3f}s  (reject at >= 1.000s below {r.get('sustained_floor',0):.3f})")
print(f"Coverage:          {r.get('coverage_seconds',0):.3f}s / {r.get('requested_coverage_seconds',0):.3f}s requested ({r.get('coverage_percent',0):.2f}% of timeline confirmed)")
print(f"VMAF frames:       {r.get('frames','?')} ({r.get('timed_frames','?')} timing-mapped)")
if r.get('reasons'):
    print('Reasons:')
    for x in r['reasons']: print(f'  - {x}')
if mode=='sampled': print('Scope:             sampled; unsampled timeline regions are not claimed as measured.')
else: print('Scope:             full timeline evidence required.')
PY
exit "$RC"
