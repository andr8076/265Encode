#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest
from unittest import mock

MODULE_PATH = pathlib.Path(__file__).with_name("legacy-intel-calibration.py")
SPEC = importlib.util.spec_from_file_location("legacy_intel_calibration", MODULE_PATH)
assert SPEC and SPEC.loader
mod = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = mod
SPEC.loader.exec_module(mod)


class CalibrationPolicyTests(unittest.TestCase):
    def test_percentile_interpolates(self):
        self.assertAlmostEqual(mod.percentile([0, 10, 20, 30], 10), 3.0)

    def test_qp_profiles_cover_tested_size_optimization_range(self):
        self.assertEqual(set(mod.PROFILES), {f"q{qp}" for qp in range(20, 37, 2)})
        self.assertEqual(mod.PROFILES["q26"][mod.PROFILES["q26"].index("-q:v") + 1], "26")
        self.assertIn("-bf", mod.PROFILES["q26"])
        self.assertIn("-refs", mod.PROFILES["q26"])

    def test_size_candidate_requires_quality_and_five_percent_saving(self):
        scores = [mod.Score(93.5, 86.0), mod.Score(89.6, 82.0), mod.Score(87.8, 81.0)]
        self.assertTrue(mod.candidate_meets_size_and_quality(scores, 950, 1000))
        self.assertFalse(mod.candidate_meets_size_and_quality(scores, 951, 1000))

    def test_size_candidate_rejects_low_overall_quality(self):
        scores = [mod.Score(91.0, 85.0), mod.Score(89.0, 82.0), mod.Score(84.0, 74.0)]
        self.assertFalse(mod.candidate_meets_size_and_quality(scores, 800, 1000))

    def test_size_candidate_rejects_a_weak_sample_window(self):
        scores = [mod.Score(96.0, 90.0), mod.Score(94.0, 88.0), mod.Score(87.4, 82.0)]
        self.assertFalse(mod.candidate_meets_size_and_quality(scores, 800, 1000))

    def test_size_candidate_rejects_low_p10_quality(self):
        scores = [mod.Score(95.0, 72.0), mod.Score(94.0, 75.0), mod.Score(93.0, 79.0)]
        self.assertFalse(mod.candidate_meets_size_and_quality(scores, 800, 1000))

    def test_size_candidate_rejects_missing_source_measurement(self):
        scores = [mod.Score(94.0, 88.0)]
        self.assertFalse(mod.candidate_meets_size_and_quality(scores, 500, 0))

    def test_media_duration_forwards_quality_runtime_environment(self):
        class Result:
            returncode = 0
            stdout = "61.5\n"
            stderr = ""

        quality_env = {"LD_LIBRARY_PATH": "/quality/lib"}
        with mock.patch.object(mod, "_run", return_value=Result()) as run:
            self.assertEqual(mod.media_duration("ffprobe", pathlib.Path("source.mov"), env=quality_env), 61.5)
        self.assertEqual(run.call_args.kwargs["env"], quality_env)


if __name__ == "__main__":
    unittest.main()
