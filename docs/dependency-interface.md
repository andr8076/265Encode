# 265Encode dependency interface

265Encode exposes semantic planning and sealed execution through protocol 2.
Its ordinary interactive and command-line workflows remain independent,
ready-to-go standalone tools.

## Negotiate before depending

```bash
265Encode.sh --machine-negotiate 2
```

The response selects the highest version shared by caller and tool. A caller
must stop when `compatible` is false. `--interface-version` prints the newest
version, while `--machine-probe` advertises the complete
`supported_protocol_versions` list.

Protocol versions establish the JSON contract. Callers that depend on optional
semantic operations must also require their corresponding `features` flags
from `--machine-probe`. This prevents a caller from sending newer additive
requirements to an older implementation that understands protocol 2 but not
those operations.

## Protocol 2: semantic evaluate/execute

The caller describes the result it needs, not FFmpeg flags or HEVC settings.
The formal input contract is
[`requirements-v2.schema.json`](requirements-v2.schema.json). Unknown fields
are rejected instead of being silently ignored.

```json
{
  "schema": "encode265.requirements",
  "protocol_version": 2,
  "input": "/archive/source.mkv",
  "output": "/archive/staging/source.hevc.mkv",
  "hardware_policy": "auto_hardware_only",
  "requested_encoder": null,
  "quality": {
    "mode": "required",
    "metric": "vmaf",
    "target": 92,
    "p10_minimum": 88,
    "sustained_floor": 86,
    "maximum_sustained_seconds": 1
  },
  "optimization": {
    "primary": "smallest_output",
    "secondary": "fastest_encoding"
  },
  "video": {"maximum_height": null, "denoise": "auto"},
  "preservation": {"streams": "all", "chapters": true, "metadata": true},
  "audio": {"mode": "copy_all"},
  "evaluation": {"sample_seconds": 3}
}
```

Evaluate the requirements without encoding the complete asset:

```bash
265Encode.sh --machine-evaluate requirements.json --plan-json plan.json
# --machine-plan is an equivalent spelling
```

265Encode selects its own encoder, quality value, preset, pixel format, and
filter behavior. It performs a real bounded sample encode and reports:

- measured sample quality (`vmaf` mean, p10, and sustained-low duration, or a
  mean-only `ssim_percent` development signal when explicitly requested);
- predicted completed output bytes;
- measured sample real-time factor and predicted completed encode time;
- the sampling basis and its explicitly limited confidence.

VMAF evaluation uses the same pinned, checksum-verified managed runtime as
`265Compare.py` when system FFmpeg lacks libvmaf. Predictions are estimates,
not completed-output acceptance evidence. Hardcore Archive should still apply
its final full or sampled acceptance policy to the completed file.

The returned `plan_id` is an opaque handle. Callers may compare predictions and
associate decisions with the ID, but must not construct it or depend on the
contents of `recipe`. Execute the saved, unchanged plan:

```bash
265Encode.sh --execute-plan plan.json --result-json result.json
```

Before encoding, 265Encode verifies the plan ID and recomputes four SHA-256
fingerprints:

| Fingerprint | Covers | Invalidation effect |
|---|---|---|
| implementation | encoder, planner, comparison code, policy version | a 265Encode improvement requires evaluation again |
| runtime | FFmpeg path/version/build, chosen encoder, available driver identity | runtime or driver changes require evaluation again |
| source | canonical path, byte length, complete content hash | changed or replaced input requires evaluation again |
| requirements | normalized semantic request | any requested outcome change requires evaluation again |

The plan ID is content-addressed from the normalized requirements, resolved
recipe, predictions, and fingerprints. Consequently, a cache keyed by plan ID
cannot reuse an old HEVC decision after 265Encode improves. Execution also
rejects stale plans directly; cache discipline is not the only safeguard.

`auto_hardware_only` never selects CPU encoding. `manual_software` is the only
semantic request that permits `libx265`. Protocol 2 requires MKV and preserves
all streams, chapters, global metadata, and stream metadata. It supports
maximum-height scaling, optional denoise, copied audio, and selective Opus audio
optimization. Quality checks may be required or explicitly disabled by the
caller.

## Compatibility and capability discovery

Callers must negotiate protocol 2 and require every optional feature they use.
Additive JSON fields may appear within a protocol version. Removing a field or
changing its meaning requires a new protocol version. The 265Encode tool version
uses semantic versioning; sealed plans additionally fingerprint the complete
implementation and runtime.

```bash
265Encode.sh --machine-probe
```

The probe performs bounded real encodes rather than trusting FFmpeg's encoder
list. It reports these protocol-2 encoder identifiers:

- `hevc_vaapi`
- `hevc_nvenc`
- `hevc_qsv`
- `hevc_qsv_legacy` (isolated Intel Media SDK compatibility runtime)
- `hevc_videotoolbox`
- `libx265` (manual software only)

`auto_encoder` is either a proven hardware encoder or `null`. Software is
never AUTO-eligible. On supported Skylake/P530 systems, the legacy backend is
automatically capability-probed and may be selected as `auto_encoder` after
modern hardware paths fail. Its runtime, driver, and tuned recipe are sealed
and fingerprinted by 265Encode. Callers must not download that runtime, choose
legacy presets, or branch on the backend name.

## Execution guarantees

Protocol-2 execution writes to a process-specific partial file and commits it
atomically only after validation. Before committing, 265Encode verifies:

- the primary output video is HEVC;
- duration remains within the bounded tolerance;
- primary video and every audio stream decode successfully;
- video, audio, subtitle, data, and attachment stream counts match the source.

For the legacy Intel backend, the isolated compatibility runtime encodes only
the primary video. The host FFmpeg then performs the final stream-preserving
mux and any requested Opus audio optimization without re-encoding that video.
Both runtimes are included in the sealed runtime fingerprint.

The atomic result uses the `encode265.plan-result` schema and includes the
opaque plan ID, prediction, selected encoder, output path, and executor result.
Exit status `0` means a validated output was committed. Invalid requests,
stale or modified plans, failed encodes, and failed validation return nonzero
without replacing the requested output.
