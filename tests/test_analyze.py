#!/usr/bin/env python3
"""Exercise the analysis command against an actual short FFmpeg video."""
from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "265Encode.sh"
SPEC = importlib.util.spec_from_file_location("encode265_analyze", ROOT / "tools" / "265Analyze.py")
assert SPEC and SPEC.loader
sys.path.insert(0, str(ROOT / "tools"))
analyzer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analyzer)


class SelectionTests(unittest.TestCase):
    def test_whole_file_size_and_quality_must_both_pass(self) -> None:
        def plan(size: int, quality: bool, score: float) -> dict:
            return {
                "selection": {"encoder": "libx265"}, "plan_id": "example",
                "recipe": {"quality": {"kind": "crf", "value": 28, "preset": "slow"}},
                "prediction": {
                    "quality": {"predicted_score": score, "target_met_on_sample": quality},
                    "size": {"predicted_output_bytes": size},
                    "speed": {"predicted_encode_seconds": 20},
                    "sample": {"count": 3}, "calibration": {"candidates": []},
                },
            }
        self.assertTrue(analyzer.summarize(plan(900, True, 94), 1000, 3, "software")["eligible"])
        self.assertEqual(analyzer.summarize(plan(990, True, 94), 1000, 3, "software")["reason"], "predicted_savings_below_minimum")
        self.assertEqual(analyzer.summarize(plan(900, False, 89), 1000, 3, "software")["reason"], "sample_quality_below_target")

    def test_analysis_and_sealed_execution_preserve_input(self) -> None:
        with tempfile.TemporaryDirectory(prefix="265analyze-test-") as raw:
            folder = Path(raw)
            source, output = folder / "video.mkv", folder / "compressed.mkv"
            subprocess.run([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12:duration=2",
                "-c:v", "ffv1", str(source),
            ], check=True)
            original_bytes = source.read_bytes()
            plan, report = folder / "plan.json", folder / "report.json"
            command = [str(SCRIPT), "--analyze", str(source), "--mode", "software",
                       "--output", str(output), "--metric", "ssim_percent",
                       "--target-vmaf", "75", "--p10-minimum", "70",
                       "--sustained-floor", "65", "--sample-seconds", "1",
                       "--plan-json", str(plan), "--report-json", str(report)]
            subprocess.run(command, check=True, capture_output=True, text=True)
            analysis = json.loads(report.read_text())
            self.assertEqual(analysis["recommendation"], "encode")
            self.assertGreaterEqual(len(analysis["candidates"][0]["tested_quality_values"]), 2)
            self.assertFalse(output.exists())
            self.assertEqual(original_bytes, source.read_bytes())
            subprocess.run([str(SCRIPT), "--execute-plan", str(plan), "--result-json",
                            str(folder / "result.json")], check=True, capture_output=True, text=True)
            codec = subprocess.check_output([
                "ffprobe", "-v", "error", "-select_streams", "V:0",
                "-show_entries", "stream=codec_name", "-of", "csv=p=0", str(output),
            ], text=True).strip()
            self.assertEqual(codec, "hevc")
            self.assertLess(output.stat().st_size, source.stat().st_size)
            self.assertEqual(original_bytes, source.read_bytes())

    def test_folder_analyzes_each_video_and_skips_existing_outputs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="265analyze-batch-") as raw:
            folder = Path(raw)
            nested = folder / "nested"
            nested.mkdir()
            source = folder / "one.mkv"
            subprocess.run([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12:duration=2",
                "-c:v", "ffv1", str(source),
            ], check=True)
            other = nested / "two.mkv"
            shutil.copy2(source, other)
            original = source.read_bytes()
            report = folder / "batch.json"
            command = [str(SCRIPT), "--analyze", str(folder), "--recursive",
                       "--mode", "software", "--metric", "ssim_percent",
                       "--target-vmaf", "75", "--p10-minimum", "70",
                       "--sustained-floor", "65", "--sample-seconds", "1", "--encode"]
            subprocess.run([*command, "--report-json", str(report)], check=True,
                           capture_output=True, text=True)
            result = json.loads(report.read_text())
            self.assertEqual(result["summary"]["encoded"], 2)
            self.assertTrue((folder / "one.hevc.mkv").is_file())
            self.assertTrue((nested / "two.hevc.mkv").is_file())
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(other.read_bytes(), original)
            second = subprocess.run(command, check=True, capture_output=True, text=True)
            self.assertIn("2 skipped_existing", second.stdout)


    def test_learn_once_batch_reuses_quality_without_evaluating_each_file(self) -> None:
        with tempfile.TemporaryDirectory(prefix="265analyze-learn-") as raw:
            folder = Path(raw)
            first, second = folder / "one.mkv", folder / "two.mkv"
            subprocess.run([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12:duration=2",
                "-c:v", "ffv1", str(first),
            ], check=True)
            shutil.copy2(first, second)
            report = folder / "batch.json"
            run = subprocess.run([
                str(SCRIPT), "--analyze", str(folder), "--learn-from", str(first),
                "--mode", "software", "--metric", "ssim_percent", "--target-vmaf", "75",
                "--p10-minimum", "70", "--sustained-floor", "65",
                "--sample-seconds", "1", "--encode", "--report-json", str(report),
            ], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            result = json.loads(report.read_text())
            self.assertEqual(result["summary"]["encoded"], 2, run.stdout)
            self.assertEqual(result["representative"]["input"], str(first))
            self.assertTrue(all("analysis" not in entry for entry in result["files"]))
            self.assertTrue((folder / "one.hevc.mkv").is_file())
            self.assertTrue((folder / "two.hevc.mkv").is_file())


if __name__ == "__main__":
    unittest.main()
