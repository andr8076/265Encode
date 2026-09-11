#!/usr/bin/env python3
"""Bounded content calibration for 265Encode's Intel Gen9 legacy HEVC path.

The safe profile was validated against libx265 CRF20/slow on multiple complete
videos. Calibration never tries to predict x265 bitrate. Instead it treats the
safe profile as the local quality reference, samples the source, and selects the
smallest proven legacy profile that remains inside a conservative VMAF envelope.
If anything is unavailable or inconclusive, callers must fall back to ``safe``.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

POLICY_VERSION = "p530-content-calibration-v1"
DEFAULT_SAMPLE_SECONDS = 3.0
DEFAULT_MAX_WINDOWS = 5
MEAN_DELTA_LIMIT = 0.80
P10_DELTA_LIMIT = 1.50
ABSOLUTE_MEAN_FLOOR = 92.0
ABSOLUTE_P10_FLOOR = 88.0

COMMON_ARGS = (
    "-c:v", "hevc_qsv",
    "-load_plugin", "hevc_hw",
    "-low_power", "0",
    "-preset:v", "veryslow",
    "-pix_fmt", "nv12",
    "-g", "600",
)

# Profiles are intentionally few and already exercised on the target P530.
# Selection is based on measured sample bytes, not this declaration order.
PROFILES: dict[str, tuple[str, ...]] = {
    "compact": COMMON_ARGS + (
        "-q:v", "19",
        "-bf", "7",
        "-refs", "4",
    ),
    "efficient": COMMON_ARGS + (
        "-q:v", "17",
        "-bf", "15",
        "-refs", "5",
    ),
    "balanced": COMMON_ARGS + (
        "-q:v", "18",
        "-i_qfactor", "-0.7777777778",
        "-i_qoffset", "0",
        "-b_qfactor", "1.0555555556",
        "-b_qoffset", "0",
        "-bf", "6",
        "-refs", "4",
    ),
    "safe": COMMON_ARGS + (
        "-q:v", "19",
        "-i_qfactor", "-0.8421052632",
        "-i_qoffset", "0",
        "-b_qfactor", "0.9473684211",
        "-b_qoffset", "0",
        "-bf", "6",
        "-refs", "4",
    ),
}


@dataclass(frozen=True)
class Window:
    start: float
    length: float


@dataclass(frozen=True)
class Score:
    mean: float
    p10: float


def percentile(values: Sequence[float], percent: float) -> float:
    if not values:
        raise ValueError("no values")
    ordered = sorted(float(v) for v in values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * (percent / 100.0)
    low = math.floor(rank)
    high = math.ceil(rank)
    if low == high:
        return ordered[low]
    fraction = rank - low
    return ordered[low] * (1.0 - fraction) + ordered[high] * fraction


def parse_vmaf_json(path: Path) -> Score:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    values: list[float] = []
    for frame in payload.get("frames", []):
        try:
            value = float(frame["metrics"]["vmaf"])
        except (KeyError, TypeError, ValueError):
            continue
        if math.isfinite(value):
            values.append(value)
    if not values:
        raise ValueError(f"no VMAF frame scores in {path}")
    return Score(statistics.fmean(values), percentile(values, 10.0))


def candidate_accepts(reference: Sequence[Score], candidate: Sequence[Score]) -> bool:
    if len(reference) != len(candidate) or not reference:
        return False
    for safe, trial in zip(reference, candidate):
        if trial.mean < ABSOLUTE_MEAN_FLOOR or trial.p10 < ABSOLUTE_P10_FLOOR:
            return False
        if safe.mean - trial.mean > MEAN_DELTA_LIMIT:
            return False
        if safe.p10 - trial.p10 > P10_DELTA_LIMIT:
            return False
    return True


def _run(command: Sequence[str], *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(command),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )


def media_duration(ffprobe: str, source: Path) -> float:
    proc = _run([
        ffprobe, "-v", "error", "-show_entries", "format=duration",
        "-of", "default=nw=1:nk=1", str(source),
    ])
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "ffprobe duration failed")
    value = float(proc.stdout.strip().splitlines()[0])
    if not math.isfinite(value) or value <= 0:
        raise ValueError("invalid media duration")
    return value


def _window_overlap(a: Window, b: Window) -> float:
    left = max(a.start, b.start)
    right = min(a.start + a.length, b.start + b.length)
    if right <= left:
        return 0.0
    return (right - left) / min(a.length, b.length)


def packet_complexity_windows(
    ffprobe: str, source: Path, duration: float, sample_seconds: float, limit: int
) -> list[Window]:
    if limit <= 0:
        return []
    command = [
        ffprobe, "-v", "error", "-select_streams", "V:0",
        "-show_packets", "-show_entries", "packet=pts_time,size",
        "-of", "csv=p=0", str(source),
    ]
    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except OSError:
        return []

    buckets: dict[int, int] = {}
    assert process.stdout is not None
    try:
        for row in csv.reader(process.stdout):
            if len(row) < 2:
                continue
            try:
                pts = float(row[0])
                size = int(row[1])
            except (ValueError, OverflowError):
                continue
            if not math.isfinite(pts) or pts < 0 or size <= 0:
                continue
            bucket = int(pts // sample_seconds)
            buckets[bucket] = buckets.get(bucket, 0) + size
    finally:
        process.stdout.close()
    if process.wait() != 0:
        return []

    result: list[Window] = []
    length = min(sample_seconds, duration)
    for bucket, _size in sorted(buckets.items(), key=lambda item: (-item[1], item[0])):
        start = min(bucket * sample_seconds, max(0.0, duration - length))
        candidate = Window(start, length)
        if any(_window_overlap(candidate, existing) >= 0.5 for existing in result):
            continue
        result.append(candidate)
        if len(result) >= limit:
            break
    return result


def plan_windows(
    ffprobe: str,
    source: Path,
    duration: float,
    sample_seconds: float = DEFAULT_SAMPLE_SECONDS,
    max_windows: int = DEFAULT_MAX_WINDOWS,
) -> list[Window]:
    length = min(sample_seconds, duration)
    if duration <= sample_seconds * 2:
        return [Window(0.0, duration)]

    uniform: list[Window] = []
    for fraction in (0.15, 0.50, 0.85):
        center = duration * fraction
        start = max(0.0, min(center - length / 2.0, duration - length))
        candidate = Window(start, length)
        if not any(_window_overlap(candidate, existing) >= 0.5 for existing in uniform):
            uniform.append(candidate)

    complexity = packet_complexity_windows(
        ffprobe, source, duration, sample_seconds, max(0, max_windows - len(uniform))
    )
    windows = list(uniform)
    for candidate in complexity:
        if len(windows) >= max_windows:
            break
        if any(_window_overlap(candidate, existing) >= 0.5 for existing in windows):
            continue
        windows.append(candidate)
    return sorted(windows, key=lambda item: item.start)


def build_legacy_env(runtime: Path, driver_dir: Path) -> dict[str, str]:
    env = os.environ.copy()
    env["INTEL_MEDIA_RUNTIME"] = "MSDK"
    old_ld = env.get("LD_LIBRARY_PATH")
    env["LD_LIBRARY_PATH"] = str(runtime / "lib") + (f":{old_ld}" if old_ld else "")
    env["LIBVA_DRIVERS_PATH"] = str(driver_dir)
    env["LIBVA_DRIVER_NAME"] = "iHD"
    return env


def build_quality_env(runtime: Path) -> dict[str, str]:
    env = os.environ.copy()
    old_ld = env.get("LD_LIBRARY_PATH")
    env["LD_LIBRARY_PATH"] = str(runtime / "lib") + (f":{old_ld}" if old_ld else "")
    return env


def encode_window(
    ffmpeg: Path,
    env: dict[str, str],
    source: Path,
    window: Window,
    profile: str,
    output: Path,
) -> int:
    command = [
        str(ffmpeg), "-nostdin", "-hide_banner", "-v", "error", "-y",
        "-ss", f"{window.start:.6f}", "-t", f"{window.length:.6f}",
        "-i", str(source),
        "-map", "0:v:0", "-an", "-sn", "-dn",
        *PROFILES[profile],
        "-f", "matroska", str(output),
    ]
    proc = _run(command, env=env)
    if proc.returncode != 0 or not output.is_file() or output.stat().st_size <= 0:
        raise RuntimeError(f"{profile} sample encode failed: {proc.stderr.strip()}")
    return output.stat().st_size


def score_window(
    ffmpeg: Path,
    env: dict[str, str],
    source: Path,
    candidate: Path,
    window: Window,
    log_path: Path,
) -> Score:
    graph = (
        "[0:v:0]settb=AVTB,setpts=PTS-STARTPTS,format=yuv420p[ref];"
        "[1:v:0]settb=AVTB,setpts=PTS-STARTPTS,format=yuv420p[dist];"
        f"[dist][ref]libvmaf=model='version=vmaf_v0.6.1':"
        f"log_fmt=json:log_path={log_path}:"
        f"n_threads={max(1, min(os.cpu_count() or 1, 8))}:n_subsample=1:ts_sync_mode=nearest"
    )
    command = [
        str(ffmpeg), "-nostdin", "-hide_banner", "-v", "error",
        "-ss", f"{window.start:.6f}", "-t", f"{window.length:.6f}",
        "-i", str(source),
        "-i", str(candidate),
        "-filter_complex", graph,
        "-an", "-f", "null", "-",
    ]
    proc = _run(command, env=env)
    if proc.returncode != 0:
        raise RuntimeError(f"VMAF scoring failed: {proc.stderr.strip()}")
    return parse_vmaf_json(log_path)


def _manifest_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cache_key(
    source: Path,
    legacy_manifest: Path,
    quality_manifest: Path,
    sample_seconds: float,
    max_windows: int,
) -> str:
    stat = source.stat()
    payload = "\0".join([
        POLICY_VERSION,
        str(source.resolve()),
        str(stat.st_size),
        str(stat.st_mtime_ns),
        _manifest_hash(legacy_manifest),
        _manifest_hash(quality_manifest),
        f"{sample_seconds:.6f}",
        str(max_windows),
    ])
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def calibrate(args: argparse.Namespace) -> tuple[str, float, int, bool]:
    source = Path(args.source).resolve()
    legacy_runtime = Path(args.legacy_runtime).resolve()
    driver_dir = Path(args.driver_dir).resolve()
    quality_runtime = Path(args.quality_runtime).resolve()
    cache_root = Path(args.cache_root).expanduser().resolve()
    cache_root.mkdir(parents=True, exist_ok=True)

    key = cache_key(
        source,
        legacy_runtime / "runtime-manifest.txt",
        quality_runtime / "runtime-manifest.txt",
        args.sample_seconds,
        args.max_windows,
    )
    cache_file = cache_root / f"{key}.json"
    if cache_file.is_file():
        try:
            cached = json.loads(cache_file.read_text(encoding="utf-8"))
            plan = cached["plan"]
            if plan in PROFILES:
                return plan, float(cached.get("ratio", 1.0)), int(cached.get("windows", 0)), True
        except (OSError, ValueError, TypeError, KeyError):
            pass

    legacy_ffmpeg = legacy_runtime / "bin" / "ffmpeg"
    quality_ffmpeg = quality_runtime / "bin" / "ffmpeg"
    quality_ffprobe = quality_runtime / "bin" / "ffprobe"
    duration = media_duration(str(quality_ffprobe), source)
    if duration < 12.0:
        return "safe", 1.0, 0, False

    windows = plan_windows(
        str(quality_ffprobe), source, duration, args.sample_seconds, args.max_windows
    )
    if not windows:
        return "safe", 1.0, 0, False

    legacy_env = build_legacy_env(legacy_runtime, driver_dir)
    quality_env = build_quality_env(quality_runtime)
    results: dict[str, tuple[list[Score], int]] = {}

    work = Path(tempfile.mkdtemp(prefix="265encode-legacy-calibration.", dir=str(cache_root)))
    try:
        for profile in ("safe", "compact", "efficient", "balanced"):
            scores: list[Score] = []
            total_bytes = 0
            profile_dir = work / profile
            profile_dir.mkdir()
            for index, window in enumerate(windows):
                encoded = profile_dir / f"{index}.mkv"
                vmaf_log = profile_dir / f"{index}.json"
                total_bytes += encode_window(
                    legacy_ffmpeg, legacy_env, source, window, profile, encoded
                )
                scores.append(
                    score_window(
                        quality_ffmpeg, quality_env, source, encoded, window, vmaf_log
                    )
                )
            results[profile] = (scores, total_bytes)

        safe_scores, safe_bytes = results["safe"]
        qualifying: list[tuple[int, str]] = [(safe_bytes, "safe")]
        for profile in ("compact", "efficient", "balanced"):
            scores, size = results[profile]
            if candidate_accepts(safe_scores, scores):
                qualifying.append((size, profile))

        selected_bytes, selected = min(qualifying, key=lambda item: (item[0], item[1]))
        ratio = selected_bytes / safe_bytes if safe_bytes > 0 else 1.0
        payload = {
            "policy": POLICY_VERSION,
            "plan": selected,
            "ratio": ratio,
            "windows": len(windows),
        }
        tmp = cache_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(tmp, cache_file)
        return selected, ratio, len(windows), False
    finally:
        shutil.rmtree(work, ignore_errors=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--legacy-runtime", required=True)
    parser.add_argument("--driver-dir", required=True)
    parser.add_argument("--quality-runtime", required=True)
    parser.add_argument("--cache-root", required=True)
    parser.add_argument("--sample-seconds", type=float, default=DEFAULT_SAMPLE_SECONDS)
    parser.add_argument("--max-windows", type=int, default=DEFAULT_MAX_WINDOWS)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if not (1.0 <= args.sample_seconds <= 8.0):
        print("sample seconds outside safety bounds", file=sys.stderr)
        return 2
    if not (1 <= args.max_windows <= 8):
        print("window count outside safety bounds", file=sys.stderr)
        return 2
    try:
        plan, ratio, windows, cached = calibrate(args)
    except Exception as exc:
        print(f"calibration failed: {exc}", file=sys.stderr)
        return 1
    print(f"{plan}|{ratio:.6f}|{windows}|{'cache' if cached else 'measured'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
