#!/usr/bin/env python3
"""Choose a smaller libx265 CRF while enforcing source-relative VMAF floors."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import statistics
import subprocess
import tempfile
from pathlib import Path

import importlib.util
import sys

HERE = Path(__file__).resolve().parent
MODULE_PATH = HERE / "legacy-intel-calibration.py"
SPEC = importlib.util.spec_from_file_location("legacy_size_policy", MODULE_PATH)
assert SPEC and SPEC.loader
policy = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = policy
SPEC.loader.exec_module(policy)

POLICY_VERSION = "libx265-size-save-v1"
CRF_CANDIDATES = (24, 26, 28, 30, 32, 34)


def run(command: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, env=env, text=True, capture_output=True, check=False)


def cache_key(source: Path, runtime_manifest: Path, ffmpeg: str, preset: str, sample_seconds: float, max_windows: int) -> str:
    stat = source.stat()
    version = run([ffmpeg, "-version"])
    encoders = run([ffmpeg, "-hide_banner", "-encoders"])
    if version.returncode or encoders.returncode or "libx265" not in encoders.stdout:
        raise RuntimeError("a working FFmpeg libx265 encoder is required")
    payload = "\0".join([
        POLICY_VERSION, str(source.resolve()), str(stat.st_size), str(stat.st_mtime_ns),
        hashlib.sha256(runtime_manifest.read_bytes()).hexdigest(),
        version.stdout.splitlines()[0], preset, f"{sample_seconds:.6f}", str(max_windows),
    ])
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def encode_window(ffmpeg: str, source: Path, window: policy.Window, crf: int, preset: str, output: Path) -> int:
    command = [
        ffmpeg, "-nostdin", "-hide_banner", "-v", "error", "-y",
        "-ss", f"{window.start:.6f}", "-t", f"{window.length:.6f}", "-i", str(source),
        "-map", "0:v:0", "-an", "-sn", "-dn", "-c:v", "libx265",
        "-crf", str(crf), "-preset", preset, "-pix_fmt", "yuv420p10le",
        "-f", "matroska", str(output),
    ]
    proc = run(command)
    if proc.returncode or not output.is_file() or output.stat().st_size <= 0:
        raise RuntimeError(f"libx265 CRF {crf} sample failed: {proc.stderr.strip()}")
    return output.stat().st_size


def calibrate(args: argparse.Namespace) -> tuple[int, float, int, bool]:
    source = Path(args.source).resolve()
    quality_runtime = Path(args.quality_runtime).resolve()
    manifest = quality_runtime / "runtime-manifest.txt"
    if not manifest.is_file():
        raise RuntimeError("the VMAF quality runtime is missing")
    cache_root = Path(args.cache_root).expanduser().resolve()
    cache_root.mkdir(parents=True, exist_ok=True)
    key = cache_key(source, manifest, args.ffmpeg, args.preset, args.sample_seconds, args.max_windows)
    cache_file = cache_root / f"{key}.json"
    if cache_file.is_file():
        try:
            cached = json.loads(cache_file.read_text(encoding="utf-8"))
            crf = int(cached["crf"])
            if crf in CRF_CANDIDATES:
                return crf, float(cached["ratio"]), int(cached["windows"]), True
        except (OSError, ValueError, TypeError, KeyError):
            pass

    qenv = os.environ.copy()
    old_ld = qenv.get("LD_LIBRARY_PATH")
    qenv["LD_LIBRARY_PATH"] = str(quality_runtime / "lib") + (f":{old_ld}" if old_ld else "")
    ffprobe = quality_runtime / "bin" / "ffprobe"
    quality_ffmpeg = quality_runtime / "bin" / "ffmpeg"
    duration = policy.media_duration(str(ffprobe), source, env=qenv)
    if duration < 12.0:
        raise RuntimeError("source is too short for reliable size and quality calibration")
    windows = policy.plan_windows(str(ffprobe), source, duration, args.sample_seconds, args.max_windows, env=qenv)
    if not windows:
        raise RuntimeError("no calibration windows could be selected from the source")
    source_bytes = policy.source_video_bytes(str(ffprobe), source, windows, env=qenv)
    work = Path(tempfile.mkdtemp(prefix="265encode-software-calibration.", dir=str(cache_root)))
    try:
        results: dict[int, tuple[list[policy.Score], int]] = {}
        for crf in CRF_CANDIDATES:
            scores: list[policy.Score] = []
            total_bytes = 0
            for index, window in enumerate(windows):
                output = work / f"crf{crf}-{index}.mkv"
                log = work / f"crf{crf}-{index}.json"
                total_bytes += encode_window(args.ffmpeg, source, window, crf, args.preset, output)
                scores.append(policy.score_window(quality_ffmpeg, qenv, source, output, window, log))
            results[crf] = scores, total_bytes

        qualifying = [
            (size, crf)
            for crf, (scores, size) in results.items()
            if policy.candidate_meets_size_and_quality(scores, size, source_bytes)
        ]
        if not qualifying:
            details = []
            for crf, (scores, size) in results.items():
                mean = statistics.fmean(score.mean for score in scores)
                worst = min(score.mean for score in scores)
                p10 = statistics.fmean(score.p10 for score in scores)
                details.append(
                    f"CRF {crf}: {size/source_bytes:.1%} size, mean {mean:.1f}, "
                    f"worst-window mean {worst:.1f}, avg-window p10 {p10:.1f}"
                )
            raise RuntimeError("no libx265 CRF meets both limits; " + "; ".join(details))
        selected_bytes, selected = min(qualifying, key=lambda item: (item[0], -item[1]))
        ratio = selected_bytes / source_bytes
        payload = {"policy": POLICY_VERSION, "crf": selected, "ratio": ratio, "windows": len(windows)}
        temp = cache_file.with_suffix(".tmp")
        temp.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temp, cache_file)
        return selected, ratio, len(windows), False
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--quality-runtime", required=True)
    parser.add_argument("--cache-root", required=True)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--preset", default="slow")
    parser.add_argument("--sample-seconds", type=float, default=3.0)
    parser.add_argument("--max-windows", type=int, default=5)
    args = parser.parse_args()
    if not (1.0 <= args.sample_seconds <= 8.0) or not (1 <= args.max_windows <= 8):
        parser.error("sample bounds are outside the supported limits")
    try:
        crf, ratio, windows, cached = calibrate(args)
    except Exception as exc:
        print(f"size-focused calibration failed: {exc}", file=sys.stderr)
        return 1
    print(f"crf{crf}|{ratio:.6f}|{windows}|{'cache' if cached else 'measured'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
