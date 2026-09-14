# 265Encode

265Encode is a ready-to-run HEVC/H.265 batch encoder for Linux and macOS.
It capability-probes real encodes before selecting hardware and keeps software
encoding behind an explicit manual choice.

## Standalone use

Run the interactive workflow:

```bash
./265Encode.sh
```

Or encode one file non-interactively:

```bash
./265Encode.sh --auto --yes movie.mkv
```

AUTO selects only a working hardware encoder. It never silently falls back to
CPU. To explicitly allow software encoding:

```bash
./265Encode.sh --software --crf 20 --preset slow --yes movie.mkv
```

Use `./265Encode.sh --help` for traversal, audio, container, overwrite, and
legacy Intel options.
## Hardware policy

Modern backends are tested with bounded real encodes:

- AMD/Mesa VA-API: `hevc_vaapi`
- NVIDIA NVENC: `hevc_nvenc`
- Intel Quick Sync: `hevc_qsv`
- Intel Skylake/P530 compatibility: `hevc_qsv_legacy`
- Apple VideoToolbox: `hevc_videotoolbox`

`libx265` is software and manual-only. On supported Skylake/P530 systems,
265Encode automatically provisions and verifies its isolated legacy runtime,
then performs content-aware quality calibration. This selection is identical
for standalone and protocol-2 callers; Hardcore Archive does not need legacy
Intel settings or special-case logic.

## Dependency interface

265Encode can be embedded without exposing FFmpeg flags to callers:

```bash
./265Encode.sh --machine-probe
./265Encode.sh --machine-negotiate 2
./265Encode.sh --machine-evaluate requirements.json --plan-json plan.json
./265Encode.sh --execute-plan plan.json --result-json result.json
```

Protocol 2 accepts semantic requirements, chooses the HEVC recipe internally,
measures representative samples, predicts quality/size/speed, and returns an
opaque content-addressed plan ID.
Execution rejects altered or stale plans by rechecking implementation, runtime,
source, and requirements fingerprints. Output is committed atomically only after
codec, duration, stream-count, and full video/audio decode validation.

The interface supports:

- hardware-only AUTO, including transparent legacy Intel selection, and explicit manual `libx265`;
- explicit backend requests for diagnostics or operator overrides;
- required VMAF/SSIM quality or caller-disabled quality checks;
- maximum-height scaling and optional denoise;
- all-stream, chapter, attachment, and metadata preservation;
- copied audio or selective archival Opus optimization.

See [the dependency interface](docs/dependency-interface.md) and
[the protocol-2 JSON schema](docs/requirements-v2.schema.json).

## Tests

```bash
bash tests/test.sh
```

The suite includes real software protocol evaluation/execution and uses a real
hardware plan when a capability-proven HEVC GPU is available.
