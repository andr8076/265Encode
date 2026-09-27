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

## Analyze a video before encoding

```bash
./265Encode.sh --analyze "movie.mkv"
./265Encode.sh --analyze "movie.mkv" --plan-json movie.plan.json --report-json movie.analysis.json
./265Encode.sh --execute-plan movie.plan.json --result-json movie.result.json
```

Analysis tests representative clips at the beginning, middle, and end of the
video. It searches quality values for the proven hardware AUTO path and CPU
`libx265`, measures VMAF against the original, and estimates their completed
sizes including the copied streams. The recommendation is the smallest tested
candidate that clears the mean, low-percentile, and sustained-dip quality
limits and predicts at least 3% whole-file savings. It recommends keeping the
source otherwise. The original resolution, all streams, chapters, and metadata
are preserved by default. No output video is made during analysis.

Use `--analyze "movie.mkv" --encode` to run the selected sealed plan directly.
The completed output is validated and rejected if it is not smaller than the
original. Analysis estimates come from short clips and are not guarantees for
the entire video. The first VMAF run may download 265Encode's verified quality
runtime when your installed FFmpeg lacks `libvmaf`. `--analyze --help` lists
quality thresholds, optional audio optimization, and JSON report options.

For a local diagnostic when VMAF is unavailable, `--metric ssim_percent`
measures mean SSIM only; its score and thresholds are not interchangeable with
VMAF or its low-frame checks.

For a folder, analyze and encode each video using settings measured for that
video:

```bash
./265Encode.sh --analyze "/path/to/videos" --encode
./265Encode.sh --analyze "/path/to/videos" --recursive --encode --report-json batch.json
./265Encode.sh --analyze "/path/to/videos" --recursive --output-dir "/path/to/converted" --encode
```

Without `--encode`, folder mode only reports recommendations. Each file gets
its own quality search and sealed execution plan; settings measured on one
video are not reused blindly for other videos. Existing outputs and generated
`.hevc.mkv` files are skipped on later runs. `--recursive` includes subfolders,
and `--output-dir` preserves that layout. A batch JSON report records the
result for every file. The batch continues after a file fails and returns a
nonzero status when any file fails.
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
