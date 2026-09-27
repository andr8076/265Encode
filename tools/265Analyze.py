#!/usr/bin/env python3
"""Sample a source with 265Encode's sealed planner and compare HEVC choices."""
from __future__ import annotations

import argparse
import math
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any

from HEVCPlan import evaluate, execute
from hevcplan_contract import PlanError, atomic_json, probe_source


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Measure representative HEVC samples and recommend the smallest quality-qualified output.")
    p.add_argument("input", type=Path, help="Video or folder to analyze")
    p.add_argument("--output", type=Path, help="Proposed .mkv output for one video (default: INPUT.hevc.mkv)")
    p.add_argument("--output-dir", type=Path, help="Folder for batch outputs; preserves subfolders with --recursive")
    p.add_argument("--recursive", action="store_true", help="Include videos in subfolders")
    p.add_argument("--mode", choices=("both", "auto", "software"), default="both", help="Compare proven hardware AUTO and CPU libx265 (default: both)")
    p.add_argument("--target-vmaf", type=float, default=93.0, help="Minimum mean VMAF in every sample (default: 93)")
    p.add_argument("--p10-minimum", type=float, default=88.0, help="Minimum tenth percentile VMAF (default: 88)")
    p.add_argument("--sustained-floor", type=float, default=86.0, help="VMAF floor for sustained dips (default: 86)")
    p.add_argument("--maximum-sustained-seconds", type=float, default=1.0)
    p.add_argument("--sample-seconds", type=float, default=3.0, help="Seconds per sample; three positions across the video")
    p.add_argument("--min-savings-percent", type=float, default=3.0, help="Required predicted whole-file saving (default: 3)")
    p.add_argument("--denoise", choices=("auto", "never", "required"), default="auto")
    p.add_argument("--optimize-audio", action="store_true", help="Allow selective archival Opus audio encoding")
    p.add_argument("--metric", choices=("vmaf", "ssim_percent"), default="vmaf", help="SSIM is a mean-only diagnostic fallback, not a substitute for VMAF")
    p.add_argument("--plan-json", type=Path, help="Save the recommended sealed plan for later --execute-plan")
    p.add_argument("--report-json", type=Path, help="Write the analysis and candidate measurements as JSON")
    p.add_argument("--encode", action="store_true", help="Execute the chosen sealed plan and validate its completed output")
    return p


def requirements(args: argparse.Namespace, input_path: Path, output: Path, mode: str) -> dict[str, Any]:
    return {
        "schema": "encode265.requirements", "protocol_version": 2,
        "input": str(input_path), "output": str(output),
        "hardware_policy": "manual_software" if mode == "software" else "auto_hardware_only",
        "requested_encoder": None,
        "quality": {"mode": "required", "metric": args.metric, "target": args.target_vmaf,
                    "p10_minimum": args.p10_minimum, "sustained_floor": args.sustained_floor,
                    "maximum_sustained_seconds": args.maximum_sustained_seconds},
        "optimization": {"primary": "smallest_output", "secondary": "highest_quality"},
        "video": {"maximum_height": None, "denoise": args.denoise},
        "preservation": {"streams": "all", "chapters": True, "metadata": True},
        "audio": {"mode": "archive_optimize" if args.optimize_audio else "copy_all"},
        "evaluation": {"sample_seconds": args.sample_seconds},
    }


def check_arguments(args: argparse.Namespace) -> tuple[Path, Path]:
    source = args.input.expanduser().resolve()
    if not source.is_file():
        raise PlanError(f"Input is not a file: {source}")
    if args.recursive:
        raise PlanError("--recursive is only valid for a folder.")
    if args.output_dir is not None:
        raise PlanError("--output-dir is only valid for a folder.")
    output = (args.output or source.with_name(source.stem + ".hevc.mkv")).expanduser().resolve()
    if output == source or output.suffix.lower() != ".mkv" or not output.parent.is_dir():
        raise PlanError("Output must be a separate .mkv path in an existing directory.")
    if output.exists():
        raise PlanError(f"Output already exists: {output}")
    if not 1 <= args.sample_seconds <= 10 or not math.isfinite(args.sample_seconds):
        raise PlanError("--sample-seconds must be between 1 and 10.")
    if not 0 <= args.min_savings_percent < 100 or not math.isfinite(args.min_savings_percent):
        raise PlanError("--min-savings-percent must be between 0 and 100.")
    for key in ("target_vmaf", "p10_minimum", "sustained_floor", "maximum_sustained_seconds"):
        value = getattr(args, key)
        if not math.isfinite(value):
            raise PlanError(f"--{key.replace('_', '-')} must be finite.")
    if not 0 <= args.sustained_floor <= args.p10_minimum <= args.target_vmaf <= 100:
        raise PlanError("Quality limits must satisfy 0 <= sustained floor <= p10 <= target <= 100.")
    if not 0 <= args.maximum_sustained_seconds <= 60:
        raise PlanError("--maximum-sustained-seconds must be between 0 and 60.")
    artifacts = [path.expanduser().resolve() for path in (args.plan_json, args.report_json) if path is not None]
    if len(set(artifacts)) != len(artifacts) or any(path in (source, output) for path in artifacts):
        raise PlanError("Plan, report, input, and output must use separate paths.")
    for path in artifacts:
        if not path.parent.is_dir():
            raise PlanError(f"Directory does not exist: {path.parent}")
        if path.exists():
            raise PlanError(f"Analysis file already exists: {path}")
    return source, output


VIDEO_EXTENSIONS = {".mp4", ".mkv", ".mov", ".avi", ".webm", ".m4v", ".ts", ".mts", ".m2ts", ".wmv", ".flv"}


def run_folder(args: argparse.Namespace) -> tuple[dict[str, Any], bool]:
    folder = args.input.expanduser().resolve()
    if args.output is not None or args.plan_json is not None:
        raise PlanError("For a folder, use --output-dir and --report-json; --output and --plan-json are for one video.")
    destination = (args.output_dir or folder).expanduser().resolve()
    if not destination.is_dir():
        raise PlanError(f"Output folder does not exist: {destination}")
    if args.report_json is not None:
        report_path = args.report_json.expanduser().resolve()
        if not report_path.parent.is_dir() or report_path.exists():
            raise PlanError(f"Report directory must exist and report must be new: {report_path}")
    paths = folder.rglob("*") if args.recursive else folder.iterdir()
    sources = sorted((path for path in paths if path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS
                      and not path.name.lower().endswith(".hevc.mkv")), key=lambda p: str(p))
    output_names = Counter((source.parent, source.stem.casefold()) for source in sources)
    report: dict[str, Any] = {"schema": "encode265.batch-analysis", "input_folder": str(folder),
                              "output_folder": str(destination), "recursive": args.recursive,
                              "metric": args.metric, "files": [], "summary": {}}
    failures = False
    print(f"Analyzing {len(sources)} video(s) in {folder}", flush=True)
    for index, source in enumerate(sources, 1):
        relative = source.relative_to(folder)
        name = source.name if output_names[(source.parent, source.stem.casefold())] > 1 else source.stem
        output = destination / relative.parent / f"{name}.hevc.mkv"
        entry: dict[str, Any] = {"input": str(source), "output": str(output)}
        if output.exists():
            entry["status"] = "skipped_existing"
        else:
            try:
                # The output tree is created only for files being analyzed.
                output.parent.mkdir(parents=True, exist_ok=True)
                single = argparse.Namespace(**vars(args))
                single.input, single.output = source, output
                single.output_dir, single.recursive = None, False
                single.report_json, single.plan_json = None, None
                result, _ = analyze(single)
                entry["analysis"] = result
                if result["recommendation"] == "keep_source":
                    if all(candidate["reason"] == "evaluation_failed" for candidate in result["candidates"]):
                        entry["status"] = "failed"
                        entry["error"] = "No encoder could complete sample evaluation."
                    else:
                        entry["status"] = "kept_source"
                else:
                    entry["status"] = "encoded" if args.encode else "recommended"
                    entry["encoder"] = result["selected_encoder"]
            except (PlanError, OSError, RuntimeError, ValueError) as exc:
                entry.update({"status": "failed", "error": str(exc)})
        report["files"].append(entry)
        failures |= entry["status"] == "failed"
        detail = f" ({entry['error']})" if entry["status"] == "failed" else ""
        print(f"[{index}/{len(sources)}] {relative}: {entry['status']}{detail}", flush=True)
    report["summary"] = {status: sum(item["status"] == status for item in report["files"])
                         for status in ("encoded", "recommended", "kept_source", "skipped_existing", "failed")}
    if args.report_json is not None:
        atomic_json(args.report_json.expanduser().resolve(), report)
    print("Batch summary: " + ", ".join(f"{number} {status}" for status, number in report["summary"].items() if number))
    return report, failures


def summarize(plan: dict[str, Any], source_bytes: int, minimum: float, mode: str) -> dict[str, Any]:
    prediction = plan["prediction"]
    estimated = int(prediction["size"]["predicted_output_bytes"])
    saving = 100 * (source_bytes - estimated) / source_bytes
    qualified = bool(prediction["quality"]["target_met_on_sample"])
    return {
        "mode": mode, "encoder": plan["selection"]["encoder"],
        "quality_value": plan["recipe"]["quality"],
        "quality": prediction["quality"], "estimated_output_bytes": estimated,
        "predicted_savings_percent": round(saving, 2),
        "predicted_encode_seconds": prediction["speed"]["predicted_encode_seconds"],
        "sample": prediction["sample"], "tested_quality_values": prediction["calibration"]["candidates"],
        "plan_id": plan["plan_id"],
        "eligible": qualified and estimated < source_bytes and saving >= minimum,
        "reason": ("eligible" if qualified and estimated < source_bytes and saving >= minimum else
                   "sample_quality_below_target" if not qualified else "predicted_savings_below_minimum"),
    }


def analyze(args: argparse.Namespace) -> tuple[dict[str, Any], dict[str, Any] | None]:
    source, output = check_arguments(args)
    source_bytes = source.stat().st_size
    if not source_bytes:
        raise PlanError("Input is empty.")
    source_info = probe_source(source)
    modes = ("software", "auto") if args.mode == "both" else (args.mode,)
    report: dict[str, Any] = {
        "schema": "encode265.analysis", "input": str(source), "output": str(output),
        "source_bytes": source_bytes, "source_video": {
            key: source_info[key] for key in ("codec", "width", "height", "bit_depth", "duration_seconds")
        }, "metric": args.metric, "minimum_predicted_savings_percent": args.min_savings_percent,
        "candidates": [], "recommendation": "keep_source", "selected_plan_id": None,
        "scope": "three representative samples; estimates are not completed-file measurements",
    }
    script = Path(__file__).resolve().parent.parent / "265Encode.sh"
    chosen: dict[str, Any] | None = None
    with tempfile.TemporaryDirectory(prefix="265encode-analysis-") as raw:
        work = Path(raw)
        for mode in modes:
            request, plan_file = work / f"{mode}-requirements.json", work / f"{mode}-plan.json"
            atomic_json(request, requirements(args, source, output, mode))
            try:
                plan = evaluate(request, plan_file, script)
            except (PlanError, RuntimeError, OSError, ValueError) as exc:
                report["candidates"].append({"mode": mode, "eligible": False, "reason": "evaluation_failed", "error": str(exc)})
                continue
            summary = summarize(plan, source_bytes, args.min_savings_percent, mode)
            report["candidates"].append(summary)
            if summary["eligible"] and (chosen is None or
                    (summary["estimated_output_bytes"], summary["predicted_encode_seconds"]) <
                    (chosen["summary"]["estimated_output_bytes"], chosen["summary"]["predicted_encode_seconds"])):
                chosen = {"plan": plan, "summary": summary}
        if chosen:
            report["recommendation"] = "encode"
            report["selected_plan_id"] = chosen["plan"]["plan_id"]
            report["selected_encoder"] = chosen["summary"]["encoder"]
            if args.plan_json:
                atomic_json(args.plan_json.expanduser().resolve(), chosen["plan"])
            if args.encode:
                plan_path = args.plan_json.expanduser().resolve() if args.plan_json else work / "selected-plan.json"
                if not args.plan_json:
                    atomic_json(plan_path, chosen["plan"])
                result_path = work / "result.json"
                report["execution"] = execute(plan_path, result_path, script)
        if args.report_json:
            atomic_json(args.report_json.expanduser().resolve(), report)
    return report, chosen


def print_report(report: dict[str, Any]) -> None:
    video = report["source_video"]
    print(f"Source: {report['input']}")
    print(f"Video: {video['width']}x{video['height']} {video['codec']}, {video['bit_depth']}-bit, {video['duration_seconds']:.1f}s")
    print(f"Size: {report['source_bytes'] / 1048576:.1f} MiB; sample metric: {report['metric']}")
    for item in report["candidates"]:
        if item["reason"] == "evaluation_failed":
            print(f"  {item['mode']}: unavailable ({item['error']})")
            continue
        quality = item["quality"]
        detail = (f", p10 {quality['predicted_p10']:.1f}, "
                  f"longest dip {quality['predicted_longest_below_floor_seconds']:.2f}s"
                  if "predicted_p10" in quality else "")
        print(f"  {item['mode']} / {item['encoder']}: {item['estimated_output_bytes'] / 1048576:.1f} MiB estimated "
              f"({item['predicted_savings_percent']:+.1f}% saved), "
              f"{report['metric']} {quality['predicted_score']:.1f}{detail}, "
              f"{item['quality_value']['kind'].upper()} {item['quality_value']['value']} "
              f"[{item['reason']}]")
    if report["recommendation"] == "encode":
        print(f"Recommended: {report['selected_encoder']} -> {report['output']}")
    else:
        print("Recommended: keep the source; no tested candidate met the size and quality limits.")
    print("Estimates cover sampled clips; the final encode is validated separately.")


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.input.expanduser().is_dir():
            _, failures = run_folder(args)
            return 1 if failures else 0
        report, _ = analyze(args)
        print_report(report)
        if report["recommendation"] == "keep_source" and all(x["reason"] == "evaluation_failed" for x in report["candidates"]):
            return 1
        return 0
    except (PlanError, OSError, RuntimeError, ValueError) as exc:
        print(f"Analysis failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
