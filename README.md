# 265Encode 3.2.0

265Encode is a ready-to-run HEVC/H.265 batch encoder for Linux and macOS.
It capability-probes real encodes before selecting hardware and preserves the
source bit depth, using software when available hardware cannot encode it.

## Standalone use

Run the interactive workflow:

```bash
./265Encode.sh
```

Or encode one file non-interactively:

```bash
./265Encode.sh --auto --yes movie.mkv
```

AUTO prefers a working hardware encoder. For sources above 8-bit, it selects
10-bit-capable hardware or falls back to CPU `libx265` to preserve bit depth.
For 8-bit sources, AUTO keeps its hardware-only behavior. To explicitly choose
software for any source:

```bash
./265Encode.sh --software --crf 20 --preset slow --yes movie.mkv
./265Encode.sh --size-focused --recursive --yes "/path/to/videos"
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

`libx265` is software. AUTO uses it only when needed to preserve a source above
8-bit and no proven 10-bit hardware encoder is available. On supported
Skylake/P530 systems, 265Encode automatically provisions and verifies its
isolated legacy runtime, then samples QP profiles against the source. It selects
the smallest candidate that clears the source-relative VMAF floor and is
predicted to use at least five percent fewer sampled video bytes. If no profile
meets both conditions, that file is skipped. All completed outputs, including
protocol-2 jobs and explicit settings, are rejected unless the final file is
smaller than its source. Use `--size-focused` to explicitly select CPU libx265
and calibrate a CRF per source file; this is slower and skips files that do not
meet both limits. For 10-bit sources on older hardware, AUTO also falls back to
10-bit CPU encoding to preserve bit depth.

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

- hardware-preferred AUTO with source bit-depth preservation, including transparent legacy Intel selection, and explicit manual `libx265`;
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
