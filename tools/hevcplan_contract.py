#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import math
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

PROTOCOL_VERSION = 2
SUPPORTED_PROTOCOLS = (2,)
REQUIREMENTS_SCHEMA = "encode265.requirements"
PLAN_SCHEMA = "encode265.plan"
RESULT_SCHEMA = "encode265.plan-result"
PLANNER_VERSION = "5"
VMAF_PLANNING_MARGIN = 0.5
DENOISE_FILTER = "hqdn3d=1.2:1.0:3.0:2.5"
LEGACY_DENOISE_FILTER = "atadenoise"
SUPPORTED_ENCODERS = {
    "hevc_vaapi", "hevc_nvenc", "hevc_qsv", "hevc_qsv_legacy",
    "hevc_videotoolbox", "libx265",
}
HARDWARE_ENCODERS = {
    "hevc_vaapi", "hevc_nvenc", "hevc_qsv", "hevc_qsv_legacy",
    "hevc_videotoolbox",
}


class PlanError(RuntimeError):
    pass


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def digest(value: Any) -> str:
    return "sha256:" + hashlib.sha256(canonical(value)).hexdigest()


def file_digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(block)
    return "sha256:" + hasher.hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PlanError(f"Could not read JSON from {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise PlanError(f"{path} must contain a JSON object.")
    return value


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=False, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def exact_keys(value: dict[str, Any], allowed: set[str], location: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise PlanError(f"Unknown {location} field(s): {', '.join(unknown)}")


def object_field(parent: dict[str, Any], name: str) -> dict[str, Any]:
    value = parent.get(name)
    if not isinstance(value, dict):
        raise PlanError(f"'{name}' must be an object.")
    return value


def finite_number(value: Any, name: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool):
        raise PlanError(f"'{name}' must be a number.")
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise PlanError(f"'{name}' must be a number.") from exc
    if not math.isfinite(number) or not minimum <= number <= maximum:
        raise PlanError(f"'{name}' must be between {minimum:g} and {maximum:g}.")
    return number


def normalize_requirements(raw: dict[str, Any]) -> dict[str, Any]:
    exact_keys(raw, {
        "schema", "protocol_version", "input", "output", "hardware_policy",
        "requested_encoder", "quality", "optimization", "video",
        "preservation", "audio", "evaluation",
    }, "requirement")
    if raw.get("schema") != REQUIREMENTS_SCHEMA:
        raise PlanError(f"'schema' must be '{REQUIREMENTS_SCHEMA}'.")
    if raw.get("protocol_version") != PROTOCOL_VERSION:
        raise PlanError(f"'protocol_version' must be {PROTOCOL_VERSION}.")

    input_path = Path(str(raw.get("input", ""))).expanduser().resolve()
    output_path = Path(str(raw.get("output", ""))).expanduser().resolve()
    if not input_path.is_file():
        raise PlanError(f"Input is not a file: {input_path}")
    if input_path == output_path:
        raise PlanError("Output must not replace the input.")
    if not output_path.parent.is_dir():
        raise PlanError(f"Output directory does not exist: {output_path.parent}")
    if output_path.suffix.lower() != ".mkv":
        raise PlanError("Protocol v2 preservation requires an .mkv output.")

    hardware_policy = raw.get("hardware_policy", "auto_hardware_only")
    if hardware_policy not in {"auto_hardware_only", "manual_software"}:
        raise PlanError("'hardware_policy' must be auto_hardware_only or manual_software.")
    requested_encoder = raw.get("requested_encoder")
    if requested_encoder in (None, "", "auto"):
        requested_encoder = None
    elif requested_encoder not in SUPPORTED_ENCODERS:
        raise PlanError("'requested_encoder' is not a supported HEVC encoder identifier.")
    if hardware_policy == "manual_software" and requested_encoder not in (None, "libx265"):
        raise PlanError("manual_software may request only libx265.")
    if hardware_policy == "auto_hardware_only" and requested_encoder == "libx265":
        raise PlanError("auto_hardware_only cannot request a software encoder.")

    quality = object_field(raw, "quality")
    exact_keys(quality, {"mode", "metric", "target", "p10_minimum", "sustained_floor", "maximum_sustained_seconds"}, "quality")
    quality_mode = quality.get("mode", "required")
    if quality_mode not in {"required", "off"}:
        raise PlanError("'quality.mode' must be required or off.")
    metric = quality.get("metric", "vmaf")
    if metric not in {"vmaf", "ssim_percent"}:
        raise PlanError("'quality.metric' must be vmaf or ssim_percent.")
    target = finite_number(quality.get("target", 0 if quality_mode == "off" else None), "quality.target", 0, 100)
    p10 = finite_number(quality.get("p10_minimum", max(0.0, target - 4)), "quality.p10_minimum", 0, 100)
    floor = finite_number(quality.get("sustained_floor", max(0.0, target - 6)), "quality.sustained_floor", 0, 100)
    maximum_sustained = finite_number(quality.get("maximum_sustained_seconds", 1), "quality.maximum_sustained_seconds", 0, 60)
    if not floor <= p10 <= target:
        raise PlanError("Quality thresholds must satisfy sustained_floor <= p10_minimum <= target.")

    optimization = object_field(raw, "optimization")
    exact_keys(optimization, {"primary", "secondary"}, "optimization")
    primary, secondary = optimization.get("primary"), optimization.get("secondary")
    objectives = {"smallest_output", "fastest_encoding", "highest_quality"}
    if primary not in objectives or secondary not in objectives or primary == secondary:
        raise PlanError("Optimization objectives must be two different supported objectives.")

    video = object_field(raw, "video")
    exact_keys(video, {"maximum_height", "denoise"}, "video")
    maximum_height = video.get("maximum_height")
    if maximum_height is not None and (isinstance(maximum_height, bool) or not isinstance(maximum_height, int) or maximum_height < 144):
        raise PlanError("'video.maximum_height' must be null or an integer of at least 144.")
    denoise = video.get("denoise", "auto")
    if denoise not in {"auto", "required", "never"}:
        raise PlanError("'video.denoise' must be auto, required, or never.")

    preservation = object_field(raw, "preservation")
    exact_keys(preservation, {"streams", "chapters", "metadata"}, "preservation")
    if preservation.get("streams") != "all" or preservation.get("chapters") is not True or preservation.get("metadata") is not True:
        raise PlanError("Protocol v2 requires all streams, chapters, and metadata.")

    audio = object_field(raw, "audio")
    exact_keys(audio, {"mode"}, "audio")
    audio_mode = audio.get("mode", "copy_all")
    if audio_mode not in {"copy_all", "archive_optimize"}:
        raise PlanError("'audio.mode' must be copy_all or archive_optimize.")

    evaluation = raw.get("evaluation", {})
    if not isinstance(evaluation, dict):
        raise PlanError("'evaluation' must be an object.")
    exact_keys(evaluation, {"sample_seconds"}, "evaluation")
    sample_seconds = finite_number(evaluation.get("sample_seconds", 3), "evaluation.sample_seconds", 1, 10)

    return {
        "schema": REQUIREMENTS_SCHEMA, "protocol_version": PROTOCOL_VERSION,
        "input": str(input_path), "output": str(output_path),
        "hardware_policy": hardware_policy, "requested_encoder": requested_encoder,
        "quality": {"mode": quality_mode, "metric": metric, "target": target, "p10_minimum": p10, "sustained_floor": floor, "maximum_sustained_seconds": maximum_sustained},
        "optimization": {"primary": primary, "secondary": secondary},
        "video": {"maximum_height": maximum_height, "denoise": denoise},
        "preservation": {"streams": "all", "chapters": True, "metadata": True},
        "audio": {"mode": audio_mode}, "evaluation": {"sample_seconds": sample_seconds},
    }


def command_output(command: list[str], env: dict[str, str] | None = None) -> str:
    result = subprocess.run(command, text=True, capture_output=True, env=env, check=False)
    if result.returncode != 0:
        raise PlanError(result.stderr.strip() or f"Command failed: {command[0]}")
    return result.stdout


def implementation_fingerprint(root: Path) -> dict[str, Any]:
    files = [
        root / "265Encode.sh", root / "tools" / "HEVCPlan.py", root / "tools" / "hevcplan_contract.py",
        root / "tools" / "hevcplan_quality.py", root / "tools" / "hevcplan_execute.py",
        root / "tools" / "265Compare.py", root / "tools" / "legacy-intel.sh",
        root / "tools" / "legacy-intel-calibration.py",
    ]
    record = {"planner_version": PLANNER_VERSION, "protocol_version": PROTOCOL_VERSION, "files": {str(path.relative_to(root)): file_digest(path) for path in files}}
    return {"algorithm": "sha256", "value": digest(record), "components": record}


def encoder_runtime(recipe: dict[str, Any], tool: str = "ffmpeg") -> tuple[str, dict[str, str]]:
    if recipe.get("encoder") != "hevc_qsv_legacy":
        executable = shutil.which(tool)
        if not executable:
            raise PlanError(f"{tool} is required.")
        return executable, os.environ.copy()
    runtime = recipe.get("runtime")
    if not isinstance(runtime, dict):
        raise PlanError("Legacy Intel recipe has no sealed runtime.")
    executable = Path(str(runtime.get(tool, "")))
    driver_dir = Path(str(runtime.get("driver_dir", "")))
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise PlanError(f"Legacy Intel {tool} is missing or not executable.")
    if not (driver_dir / "iHD_drv_video.so").is_file():
        raise PlanError("Legacy Intel driver is missing from the isolated runtime.")
    environment = os.environ.copy()
    environment.update({
        "INTEL_MEDIA_RUNTIME": "MSDK",
        "LD_LIBRARY_PATH": str(executable.parent.parent / "lib"),
        "LIBVA_DRIVERS_PATH": str(driver_dir),
        "LIBVA_DRIVER_NAME": "iHD",
    })
    return str(executable), environment


def runtime_fingerprint(encoder: str, recipe: dict[str, Any]) -> dict[str, Any]:
    ffmpeg, environment = encoder_runtime(recipe)
    ffprobe, _ = encoder_runtime(recipe, "ffprobe")
    components: dict[str, Any] = {
        "ffmpeg_path": str(Path(ffmpeg).resolve()), "ffprobe_path": str(Path(ffprobe).resolve()),
        "ffmpeg_version": command_output([ffmpeg, "-version"], environment).splitlines()[0],
        "ffmpeg_buildconf": command_output([ffmpeg, "-buildconf"], environment), "encoder": encoder,
    }
    if encoder == "hevc_qsv_legacy":
        runtime = recipe["runtime"]
        manifest = Path(runtime["manifest"])
        driver = Path(runtime["driver_dir"]) / "iHD_drv_video.so"
        if not manifest.is_file():
            raise PlanError("Legacy Intel runtime manifest is missing.")
        host_ffmpeg, host_ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
        if not host_ffmpeg or not host_ffprobe:
            raise PlanError("Host ffmpeg and ffprobe are required for legacy stream preservation.")
        components.update({
            "runtime_manifest": file_digest(manifest),
            "driver": file_digest(driver),
            "host_ffmpeg_path": str(Path(host_ffmpeg).resolve()),
            "host_ffprobe_path": str(Path(host_ffprobe).resolve()),
            "host_ffmpeg_version": command_output([host_ffmpeg, "-version"]).splitlines()[0],
            "host_ffmpeg_buildconf": command_output([host_ffmpeg, "-buildconf"]),
        })
    for tool, args in (("nvidia-smi", ["--query-gpu=name,driver_version", "--format=csv,noheader"]), ("vainfo", [])):
        executable = shutil.which(tool)
        if executable:
            result = subprocess.run([executable, *args], text=True, capture_output=True, check=False)
            components[tool] = (result.stdout + result.stderr).strip()
    return {"algorithm": "sha256", "value": digest(components), "components": components}


def source_fingerprint(path: Path) -> dict[str, Any]:
    stat = path.stat()
    components = {"path": str(path), "bytes": stat.st_size, "content": file_digest(path)}
    return {"algorithm": "sha256", "value": digest(components), "components": components}


def probe_source(path: Path) -> dict[str, Any]:
    data = json.loads(command_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]))
    streams = data.get("streams") or []
    primary = next((item for item in streams if item.get("codec_type") == "video" and not (item.get("disposition") or {}).get("attached_pic")), None)
    if primary is None:
        raise PlanError("Input has no primary video stream.")
    duration = float((data.get("format") or {}).get("duration") or 0)
    width, height = int(primary.get("width") or 0), int(primary.get("height") or 0)
    if duration <= 0 or width <= 0 or height <= 0:
        raise PlanError("Input duration or dimensions could not be determined.")
    try: format_bitrate = max(0, int((data.get("format") or {}).get("bit_rate") or 0))
    except (TypeError, ValueError): format_bitrate = 0
    copied_bitrate, audio_tracks = 0, []
    for item in streams:
        if item is primary: continue
        try: bitrate = max(0, int(item.get("bit_rate") or 0))
        except (TypeError, ValueError): bitrate = 0
        copied_bitrate += bitrate
        if item.get("codec_type") == "audio":
            audio_tracks.append({"input_index": int(item.get("index") or 0), "codec": str(item.get("codec_name") or "unknown"), "channels": int(item.get("channels") or 2), "bitrate": bitrate})
    return {"duration_seconds": duration, "width": width, "height": height, "codec": str(primary.get("codec_name") or ""), "primary_stream_index": int(primary.get("index") or 0), "streams": streams, "audio_tracks": audio_tracks, "format_bitrate": format_bitrate, "copied_stream_bitrate": copied_bitrate}


def capabilities(script: Path) -> dict[str, Any]:
    return json.loads(command_output([str(script), "--machine-probe"]))


def choose_encoder(requirements: dict[str, Any], report: dict[str, Any]) -> tuple[str, str, dict[str, Any]]:
    encoders = {item.get("name"): item for item in report.get("encoders", []) if isinstance(item, dict)}
    requested, policy = requirements.get("requested_encoder"), requirements["hardware_policy"]
    if requested:
        chosen = encoders.get(requested)
        if not chosen or chosen.get("usable") is not True:
            raise PlanError(f"Requested HEVC encoder is not capability-proven usable: {requested}")
        encoder_class = str(chosen.get("class") or "")
        if policy == "manual_software" and encoder_class != "software": raise PlanError("Requested encoder violates manual_software policy.")
        if policy == "auto_hardware_only" and encoder_class != "hardware": raise PlanError("Requested encoder violates auto_hardware_only policy.")
        return requested, encoder_class, chosen
    if policy == "manual_software":
        chosen = encoders.get("libx265")
        if not chosen or chosen.get("usable") is not True: raise PlanError("Manual software encoding was requested, but libx265 is not usable.")
        return "libx265", "software", chosen
    name, chosen = report.get("auto_encoder"), encoders.get(report.get("auto_encoder"))
    if not name or not chosen or chosen.get("usable") is not True or chosen.get("class") != "hardware": raise PlanError("No proven hardware HEVC encoder satisfies auto_hardware_only.")
    return str(name), "hardware", chosen


def _listed(kind: str, name: str) -> bool:
    result = subprocess.run(["ffmpeg", "-hide_banner", f"-{kind}"], text=True, capture_output=True, check=False)
    return result.returncode == 0 and any(line.split()[1:2] == [name] for line in result.stdout.splitlines())


def _audio_recipe(requirements: dict[str, Any], source: dict[str, Any]) -> dict[str, Any]:
    mode, opus, tracks, estimated = requirements["audio"]["mode"], _listed("encoders", "libopus"), [], 0
    for number, track in enumerate(source["audio_tracks"]):
        channels, codec, bitrate = max(1, int(track["channels"] or 2)), str(track["codec"]), int(track["bitrate"] or 0)
        target = 80_000 if channels == 1 else 128_000 if channels == 2 else 192_000 if channels <= 4 else 256_000 if channels <= 6 else 320_000
        convert = False
        if mode == "archive_optimize" and opus:
            if codec == "opus": convert = False
            elif codec.startswith("pcm_") or codec in {"flac", "truehd", "dts"}: convert = True
            elif codec == "aac": convert = bitrate == 0 or bitrate > target * 5 // 4
            else: convert = bitrate > target * 3 // 2
        tracks.append({"output_audio_index": number, "mode": "opus", "bitrate": target} if convert else {"output_audio_index": number, "mode": "copy"})
        estimated += target if convert else (bitrate if bitrate > 0 else 192_000)
    return {"mode": mode, "tracks": tracks, "estimated_bitrate": estimated}


def _legacy_runtime(capability: dict[str, Any]) -> dict[str, str]:
    runtime = capability.get("runtime")
    if not isinstance(runtime, dict):
        raise PlanError("The legacy Intel capability did not report its isolated runtime.")
    result = {name: str(runtime.get(name, "")) for name in ("ffmpeg", "ffprobe", "manifest", "driver_dir")}
    if not all(Path(result[name]).is_absolute() for name in result):
        raise PlanError("The legacy Intel capability reported a non-absolute runtime path.")
    for name in ("ffmpeg", "ffprobe", "manifest"):
        if not Path(result[name]).is_file():
            raise PlanError(f"The legacy Intel runtime is missing {name}.")
    if not (Path(result["driver_dir"]) / "iHD_drv_video.so").is_file():
        raise PlanError("The legacy Intel runtime is missing its isolated driver.")
    return result


def _legacy_filter_available(runtime: dict[str, str], name: str) -> bool:
    recipe = {"encoder": "hevc_qsv_legacy", "runtime": runtime}
    ffmpeg, environment = encoder_runtime(recipe)
    result = subprocess.run([ffmpeg, "-hide_banner", "-filters"], env=environment, text=True, capture_output=True, check=False)
    return result.returncode == 0 and any(line.split()[1:2] == [name] for line in result.stdout.splitlines())


def recipe_for(encoder: str, requirements: dict[str, Any], source: dict[str, Any], capability: dict[str, Any]) -> dict[str, Any]:
    if encoder == "libx265":
        quality = {"kind": "crf", "value": 20, "preset": "slow"}
    elif encoder == "hevc_qsv_legacy":
        quality = {"kind": "qp", "value": 19, "preset": "legacy-safe-v1"}
    elif encoder == "hevc_videotoolbox":
        # Store a loss-oriented index so a larger value consistently means
        # lower quality across every backend. FFmpeg receives 100 - value.
        quality = {"kind": "quality_index", "value": 35, "preset": "platform-default"}
    else:
        quality = {"kind": "qp", "value": 24, "preset": "slow"}
    maximum = requirements["video"]["maximum_height"]
    target_height = source["height"] if maximum is None else min(source["height"], maximum)
    target_width = source["width"] if target_height == source["height"] else max(2, int(round((source["width"] * target_height / source["height"]) / 2.0) * 2))
    denoise_mode = requirements["video"]["denoise"]
    legacy_runtime = _legacy_runtime(capability) if encoder == "hevc_qsv_legacy" else None
    denoise_name = "atadenoise" if legacy_runtime else "hqdn3d"
    denoise_filter = LEGACY_DENOISE_FILTER if legacy_runtime else DENOISE_FILTER
    denoise_available = _listed("filters", denoise_name) and (
        legacy_runtime is None or _legacy_filter_available(legacy_runtime, denoise_name)
    )
    if denoise_mode == "required" and not denoise_available:
        raise PlanError(f"Denoising was required, but the selected runtime does not provide {denoise_name}.")
    denoise = denoise_available and (denoise_mode == "required" or (denoise_mode == "auto" and (source["codec"] in {"mpeg1video", "mpeg2video", "mpeg4", "wmv1", "wmv2"} or (source["height"] <= 720 and source["format_bitrate"] >= 12_000_000))))
    recipe: dict[str, Any] = {
        "encoder": encoder, "quality": quality,
        "resolution": {"mode": "source" if target_height == source["height"] else "maximum_height", "width": target_width, "height": target_height},
        "denoise": {"mode": denoise_name if denoise else "none", "filter": denoise_filter if denoise else None},
        "container": "matroska", "audio": _audio_recipe(requirements, source), "preserve_all": True,
    }
    if encoder == "hevc_qsv_legacy":
        recipe["runtime"] = legacy_runtime
        recipe["legacy_profile"] = "safe-v1"
    if encoder == "hevc_vaapi":
        detail, device = str(capability.get("detail", "")), str(capability.get("detail", "")).split(",", 1)[0]
        if not device.startswith("/dev/"): raise PlanError("The selected VA-API capability did not report its render device.")
        recipe["vaapi_device"], recipe["vaapi_upload_format"] = device, ("p010le" if "10-bit" in detail else "nv12")
    return recipe


def planning_quality_target(quality: dict[str, Any]) -> tuple[float, float]:
    margin = VMAF_PLANNING_MARGIN if quality.get("mode", "required") == "required" and quality["metric"] == "vmaf" else 0.0
    return min(100.0, float(quality["target"]) + margin), margin
