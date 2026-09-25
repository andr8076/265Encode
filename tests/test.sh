#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

bash -n "$ROOT/265Encode.sh" "$ROOT/tools/legacy-intel.sh"
python3 -m py_compile \
    "$ROOT/tools/265Compare.py" \
    "$ROOT/tools/software-size-calibration.py" \
    "$ROOT/tools/HEVCPlan.py" \
    "$ROOT/tools/hevcplan_contract.py" \
    "$ROOT/tools/hevcplan_quality.py" \
    "$ROOT/tools/hevcplan_execute.py" \
    "$ROOT/tools/legacy-intel-calibration.py"

[[ $("$ROOT/265Encode.sh" --version) == "265Encode.sh 3.2.0" ]]
[[ $("$ROOT/265Encode.sh" --interface-version) == 2 ]]
"$ROOT/265Encode.sh" --machine-negotiate 1 |
    python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["compatible"] is False'
"$ROOT/265Encode.sh" --machine-negotiate 1,2 |
    python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["selected_protocol_version"] == 2'

"$ROOT/265Encode.sh" --machine-probe | python3 -c '
import json, sys
value=json.load(sys.stdin)
assert value["schema"] == "encode265.capabilities"
assert value["supported_protocol_versions"] == [2]
assert value["codec"] == "hevc"
assert value["auto_policy"] == "hardware_only"
features=value["features"]
required={"semantic_planning","opaque_plan_id","fingerprint_invalidation",
"sampled_predictions","semantic_requested_encoder","semantic_quality_off",
          "semantic_scaling","semantic_denoise","semantic_audio_optimize",
          "preserve_all","full_decode_validation"}
assert all(features.get(name) is True for name in required)
records={item["name"]:item for item in value["encoders"]}
assert records["libx265"]["class"] == "software"
assert records["libx265"]["auto_eligible"] is False
assert records["hevc_qsv_legacy"]["class"] == "hardware"
assert records["hevc_qsv_legacy"]["auto_eligible"] is True
auto=value["auto_encoder"]
assert auto is None or (
    records[auto]["class"] == "hardware" and records[auto]["usable"] is True
)
assert features["legacy_intel_protocol2"] is True
assert features["legacy_intel_auto_transparent"] is True
'

python3 - "$ROOT/265Encode.sh" <<'PY'
import pathlib, sys
text=pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
body=text.split("configure_encoder() {",1)[1].split("\nanalyze_video() {",1)[0]
auto=body.split('if [[ "$selected_mode" == "auto" ]]',1)[1].split("\n    fi",1)[0]
assert 'selected_mode="hardware"' in auto
assert 'selected_mode="software"' not in auto
assert 'Select mode [1]:' in text
assert 'MODE="auto"' in text
assert 'validate_completed_output "$input_file" "$temporary_output"' in text
assert 'candidate_size >= source_size' in text
assert 'configure_size_focused_software_file' in text
assert 'SIZE_FOCUSED_MODE="yes"' in text
assert 'no tested legacy QP meets the size and quality limits' in text
assert 'Completed output was rejected and removed; the input is unchanged.' in text
PY

python3 -m json.tool "$ROOT/docs/requirements-v2.schema.json" >/dev/null
python3 "$ROOT/tools/test_legacy_intel_calibration.py"
python3 "$ROOT/tools/test_size_guard.py"
bash "$ROOT/tests/semantic-v2.sh"
printf '265Encode policy and protocol tests passed.\n'
