#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/encode265-semantic-v2.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

ffmpeg -hide_banner -encoders 2>/dev/null | awk 'NF >= 2 && $2 == "libx265" {found=1} END {exit(found ? 0 : 1)}' || {
    printf 'libx265 unavailable; semantic software integration skipped.\n'
    exit 0
}

printf '1\n00:00:00,000 --> 00:00:00,800\nHEVC integration subtitle\n' > "$TMP/subtitle.srt"
printf 'attachment payload\n' > "$TMP/attachment.txt"
printf ';FFMETADATA1\ntitle=265Encode integration\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=800\ntitle=Opening\n' > "$TMP/metadata.ffmeta"

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc2=size=320x180:rate=12:duration=2' \
    -f lavfi -i 'sine=frequency=440:duration=2' \
    -f lavfi -i 'sine=frequency=880:duration=2' \
    -f srt -i "$TMP/subtitle.srt" \
    -f ffmetadata -i "$TMP/metadata.ffmeta" \
    -map 0:v -map 1:a -map 2:a -map 3:s -map_metadata 4 -map_chapters 4 \
    -c:v ffv1 -c:a pcm_s16le -c:s srt \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=dan \
    -attach "$TMP/attachment.txt" -metadata:s:t mimetype=text/plain \
    "$TMP/source.mkv"

cat > "$TMP/requirements.json" <<JSON
{
  "schema": "encode265.requirements",
  "protocol_version": 2,
  "input": "$TMP/source.mkv",
  "output": "$TMP/output.mkv",
  "hardware_policy": "manual_software",
  "requested_encoder": "libx265",
  "quality": {
    "mode": "required",
    "metric": "ssim_percent",
    "target": 80,
    "p10_minimum": 76,
    "sustained_floor": 74,
    "maximum_sustained_seconds": 1
  },
  "optimization": {"primary": "smallest_output", "secondary": "fastest_encoding"},
  "video": {"maximum_height": 144, "denoise": "required"},
  "preservation": {"streams": "all", "chapters": true, "metadata": true},
  "audio": {"mode": "archive_optimize"},
  "evaluation": {"sample_seconds": 1}
}
JSON

"$ROOT/265Encode.sh" --machine-evaluate "$TMP/requirements.json" --plan-json "$TMP/plan.json" >/dev/null
python3 - "$TMP/plan.json" <<'PY'
import json, sys
plan=json.load(open(sys.argv[1], encoding='utf-8'))
assert plan['selection']['encoder'] == 'libx265'
assert plan['selection']['class'] == 'software'
assert plan['recipe']['resolution']['height'] == 144
assert plan['recipe']['resolution']['mode'] == 'maximum_height'
assert plan['recipe']['denoise']['mode'] == 'hqdn3d'
assert plan['recipe']['audio']['mode'] == 'archive_optimize'
assert plan['execution']['state'] == 'ready'
assert plan['prediction']['quality']['target_met_on_sample'] is True
PY

"$ROOT/265Encode.sh" --execute-plan "$TMP/plan.json" --result-json "$TMP/result.json" >/dev/null
[[ -s "$TMP/output.mkv" ]]
[[ $(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name -of csv=p=0 "$TMP/output.mkv") == hevc ]]
[[ $(ffprobe -v error -select_streams V:0 -show_entries stream=height -of csv=p=0 "$TMP/output.mkv") == 144 ]]
python3 - "$TMP/source.mkv" "$TMP/output.mkv" <<'PY'
import json, subprocess, sys

def probe(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_chapters",
        "-show_format", "-of", "json", path,
    ], text=True))

source, output = map(probe, sys.argv[1:])
def counts(value):
    result = {}
    for stream in value["streams"]:
        kind = stream["codec_type"]
        result[kind] = result.get(kind, 0) + 1
    return result

assert counts(output) == counts(source)
audio = [stream for stream in output["streams"] if stream["codec_type"] == "audio"]
assert [stream.get("tags", {}).get("language") for stream in audio] == ["eng", "dan"]
assert len(output.get("chapters", [])) == 1
assert output.get("format", {}).get("tags", {}).get("title") == "265Encode integration"
PY
if ffmpeg -hide_banner -encoders 2>/dev/null | awk 'NF >= 2 && $2 == "libopus" {found=1} END {exit(found ? 0 : 1)}'; then
    [[ $(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$TMP/output.mkv") == opus ]]
fi

python3 - "$TMP/requirements.json" "$TMP/off.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1], encoding='utf-8'))
value['output']=sys.argv[2].replace('off.json','off-output.mkv')
value['quality']={'mode':'off','metric':'vmaf','target':0,'p10_minimum':0,'sustained_floor':0,'maximum_sustained_seconds':1}
value['video']={'maximum_height':None,'denoise':'never'}
value['audio']={'mode':'copy_all'}
json.dump(value, open(sys.argv[2], 'w', encoding='utf-8'))
PY
"$ROOT/265Encode.sh" --machine-evaluate "$TMP/off.json" --plan-json "$TMP/off-plan.json" >/dev/null
python3 - "$TMP/off-plan.json" <<'PY'
import json, sys
plan=json.load(open(sys.argv[1], encoding='utf-8'))
assert plan['prediction']['quality']['metric'] == 'disabled'
assert plan['execution']['state'] == 'ready'
PY

auto_encoder=$("$ROOT/265Encode.sh" --machine-probe | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("auto_encoder") or "")')
if [[ -n $auto_encoder ]]; then
    python3 - "$TMP/off.json" "$TMP/hardware.json" "$auto_encoder" <<'PY'
import json, sys
value=json.load(open(sys.argv[1], encoding='utf-8'))
value['output']=value['output'].replace('off-output.mkv','hardware-output.mkv')
value['hardware_policy']='auto_hardware_only'
value['requested_encoder']=sys.argv[3]
json.dump(value, open(sys.argv[2], 'w', encoding='utf-8'))
PY
    "$ROOT/265Encode.sh" --machine-evaluate "$TMP/hardware.json" \
        --plan-json "$TMP/hardware-plan.json" >/dev/null
    "$ROOT/265Encode.sh" --execute-plan "$TMP/hardware-plan.json" \
        --result-json "$TMP/hardware-result.json" >/dev/null
    [[ $(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name \
        -of csv=p=0 "$TMP/hardware-output.mkv") == hevc ]]
    python3 - "$TMP/hardware-plan.json" "$auto_encoder" <<'PY'
import json, sys
plan=json.load(open(sys.argv[1], encoding='utf-8'))
assert plan['selection']['encoder'] == sys.argv[2]
assert plan['selection']['class'] == 'hardware'
PY
fi

cp "$TMP/plan.json" "$TMP/tampered-plan.json"
python3 - "$TMP/tampered-plan.json" <<'PY'
import json, sys
path=sys.argv[1]
plan=json.load(open(path, encoding='utf-8'))
plan['recipe']['quality']['value'] += 1
json.dump(plan, open(path, 'w', encoding='utf-8'))
PY
if "$ROOT/265Encode.sh" --execute-plan "$TMP/tampered-plan.json" \
    --result-json "$TMP/tampered-result.json" >/dev/null 2>&1; then
    printf 'Tampered plan was accepted.\n' >&2
    exit 1
fi
python3 - "$TMP/tampered-result.json" <<'PY'
import json, sys
result=json.load(open(sys.argv[1], encoding='utf-8'))
assert result['schema'] == 'encode265.error'
assert result['status'] == 'failed'
assert 'integrity' in result['error'].lower()
PY

printf 'source changed\n' >> "$TMP/source.mkv"
if "$ROOT/265Encode.sh" --execute-plan "$TMP/off-plan.json" \
    --result-json "$TMP/stale-result.json" >/dev/null 2>&1; then
    printf 'Stale source plan was accepted.\n' >&2
    exit 1
fi
python3 - "$TMP/stale-result.json" <<'PY'
import json, sys
result=json.load(open(sys.argv[1], encoding='utf-8'))
assert result['schema'] == 'encode265.error'
assert 'source fingerprint changed' in result['error']
PY

PYTHONPATH="$ROOT/tools" python3 - <<'PY'
import tempfile
from pathlib import Path
from unittest import mock
import hevcplan_execute as executor
from hevcplan_contract import _legacy_filter_available, choose_encoder, encoder_runtime, runtime_fingerprint
from hevcplan_quality import software_filter, video_encode_args
req={'hardware_policy':'auto_hardware_only','requested_encoder':'hevc_nvenc'}
report={'auto_encoder':'hevc_qsv','encoders':[{'name':'hevc_nvenc','usable':True,'class':'hardware'},{'name':'hevc_qsv','usable':True,'class':'hardware'}]}
assert choose_encoder(req, report)[:2] == ('hevc_nvenc','hardware')
req={'hardware_policy':'auto_hardware_only','requested_encoder':None}
legacy={'name':'hevc_qsv_legacy','usable':True,'class':'hardware'}
report={'auto_encoder':'hevc_qsv_legacy','encoders':[legacy]}
assert choose_encoder(req, report) == ('hevc_qsv_legacy','hardware',legacy)
recipe={
    'encoder':'hevc_qsv_legacy',
    'quality':{'kind':'qp','value':19,'preset':'legacy-safe-v1'},
    'resolution':{'mode':'source','width':640,'height':360},
    'denoise':{'mode':'none','filter':None},
}
global_args,video_args=video_encode_args('hevc_qsv_legacy',recipe)
assert global_args == []
assert video_args[:6] == ['-c:v:0','hevc_qsv','-load_plugin','hevc_hw','-low_power','0']
assert '-q:v:0' in video_args and video_args[video_args.index('-q:v:0')+1] == '19'
assert '-i_qfactor:v:0' in video_args and '-b_qfactor:v:0' in video_args
assert video_args[video_args.index('-pix_fmt:v:0')+1] == 'nv12'
with tempfile.TemporaryDirectory() as raw:
    root=Path(raw); (root/'bin').mkdir(); (root/'lib/dri').mkdir(parents=True)
    for name in ('ffmpeg','ffprobe'):
        tool=root/'bin'/name
        tool.write_text('#!/bin/sh\nprintf " TS atadenoise V->V\n"\n',encoding='utf-8')
        tool.chmod(0o755)
    (root/'runtime-manifest.txt').write_text('runtime_kind=intel-media-sdk-legacy\n',encoding='utf-8')
    (root/'lib/dri/iHD_drv_video.so').write_text('driver',encoding='utf-8')
    recipe['runtime']={'ffmpeg':str(root/'bin/ffmpeg'),'ffprobe':str(root/'bin/ffprobe'),'manifest':str(root/'runtime-manifest.txt'),'driver_dir':str(root/'lib/dri')}
    executable,environment=encoder_runtime(recipe)
    assert executable == str(root/'bin/ffmpeg')
    assert environment['INTEL_MEDIA_RUNTIME'] == 'MSDK'
    assert environment['LIBVA_DRIVER_NAME'] == 'iHD'
    fingerprint=runtime_fingerprint('hevc_qsv_legacy',recipe)
    assert fingerprint['components']['runtime_manifest'].startswith('sha256:')
    assert fingerprint['components']['driver'].startswith('sha256:')
    assert _legacy_filter_available(recipe['runtime'],'atadenoise') is True
    recipe['denoise']={'mode':'atadenoise','filter':'atadenoise'}
    assert software_filter(recipe) == 'atadenoise'
    recipe['audio']={'tracks':[{'output_audio_index':0,'mode':'opus','bitrate':128000}]}
    requirements={'input':str(root/'source.mkv'),'output':str(root/'output.mkv')}
    (root/'source.mkv').write_text('source',encoding='utf-8')
    source={'primary_stream_index':0,'streams':[{'index':0},{'index':1}]}
    commands=[]
    def fake_run(command,**kwargs):
        commands.append(command); Path(command[-1]).write_text('encoded',encoding='utf-8')
        return type('Result',(),{'returncode':0,'stderr':''})()
    def fake_runtime(value,tool='ffmpeg'):
        return ('/legacy/ffmpeg' if value.get('encoder')=='hevc_qsv_legacy' else '/host/ffmpeg'),{}
    with mock.patch.object(executor,'encoder_runtime',side_effect=fake_runtime), mock.patch.object(executor.subprocess,'run',side_effect=fake_run), mock.patch.object(executor,'validate_output'):
        executor.execute_direct(requirements,recipe,source)
    assert len(commands)==2 and '-an' in commands[0]
    assert commands[1][0]=='/host/ffmpeg' and 'libopus' in commands[1]
    assert commands[1][commands[1].index('-map')+1]=='0:v:0'
    assert '1:1' in commands[1]
PY

printf 'Extended protocol-v2 semantic ownership tests passed.\n'
