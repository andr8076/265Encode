#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys
import tempfile
import unittest
from unittest import mock

TOOLS = pathlib.Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
import hevcplan_execute as executor  # noqa: E402


class SizeGuardTests(unittest.TestCase):
    def test_protocol_rejects_output_larger_than_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            source = root / "source.mp4"
            output = root / "output.mkv"
            source.write_bytes(b"x" * 100)
            output.write_bytes(b"x" * 101)
            with self.assertRaisesRegex(executor.PlanError, "not smaller than the source"):
                executor.validate_output(source, output)

    def test_protocol_rejects_output_equal_to_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            source = root / "source.mp4"
            output = root / "output.mkv"
            source.write_bytes(b"x" * 100)
            output.write_bytes(b"x" * 100)
            with self.assertRaisesRegex(executor.PlanError, "not smaller than the source"):
                executor.validate_output(source, output)


if __name__ == "__main__":
    unittest.main()
