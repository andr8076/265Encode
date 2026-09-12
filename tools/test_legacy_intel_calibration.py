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

    def test_candidate_within_safe_envelope_is_accepted(self):
        safe = [mod.Score(98.0, 95.0), mod.Score(95.0, 90.0)]
        trial = [mod.Score(97.3, 93.6), mod.Score(94.3, 88.6)]
        self.assertTrue(mod.candidate_accepts(safe, trial))

    def test_cpu_match_accepts_small_controlled_loss(self):
        cpu = [mod.Score(96.5, 91.7), mod.Score(94.0, 87.5)]
        trial = [mod.Score(96.0, 90.9), mod.Score(93.5, 86.7)]
        self.assertTrue(mod.candidate_matches_cpu(cpu, trial))

    def test_cpu_match_rejects_excess_p10_loss(self):
        cpu = [mod.Score(96.5, 91.7)]
        trial = [mod.Score(96.2, 90.79)]
        self.assertFalse(mod.candidate_matches_cpu(cpu, trial))

    def test_cpu_match_does_not_force_global_floor_above_cpu_window(self):
        cpu = [mod.Score(91.5, 86.0)]
        trial = [mod.Score(91.0, 85.2)]
        self.assertTrue(mod.candidate_matches_cpu(cpu, trial))

    def test_mean_regression_is_rejected(self):
        safe = [mod.Score(98.0, 95.0)]
        trial = [mod.Score(97.19, 94.9)]
        self.assertFalse(mod.candidate_accepts(safe, trial))

    def test_p10_regression_is_rejected(self):
        safe = [mod.Score(98.0, 95.0)]
        trial = [mod.Score(97.9, 93.49)]
        self.assertFalse(mod.candidate_accepts(safe, trial))

    def test_absolute_p10_floor_is_enforced(self):
        safe = [mod.Score(93.0, 88.5)]
        trial = [mod.Score(92.8, 87.99)]
        self.assertFalse(mod.candidate_accepts(safe, trial))

    def test_safe_profile_is_exact_verified_frontier(self):
        args = mod.PROFILES["safe"]
        joined = " ".join(args)
        self.assertIn("-q:v 19", joined)
        self.assertIn("-bf 6", joined)
        self.assertIn("-refs 4", joined)
        self.assertIn("-g 600", joined)
        self.assertIn("-i_qfactor -0.8421052632", joined)
        self.assertIn("-b_qfactor 0.9473684211", joined)

    def test_media_duration_forwards_quality_runtime_environment(self):
        class Result:
            returncode = 0
            stdout = "61.5\n"
            stderr = ""

        quality_env = {"LD_LIBRARY_PATH": "/quality/lib"}
        with mock.patch.object(mod, "_run", return_value=Result()) as run:
            self.assertEqual(mod.media_duration("ffprobe", pathlib.Path("source.mov"), env=quality_env), 61.5)
        self.assertEqual(run.call_args.kwargs["env"], quality_env)

    def test_matched_profile_is_validated_frontier(self):
        joined = " ".join(mod.PROFILES["matched"])
        self.assertIn("-q:v 18", joined)
        self.assertIn("-b_qfactor 1", joined)
        self.assertIn("-b_qoffset 2", joined)
        self.assertIn("-bf 15", joined)
        self.assertIn("-refs 5", joined)

    def test_profile_set_is_bounded(self):
        self.assertEqual(set(mod.PROFILES), {"compact", "efficient", "matched", "balanced", "safe"})
        self.assertLessEqual(len(mod.PROFILES), 5)


if __name__ == "__main__":
    unittest.main()
