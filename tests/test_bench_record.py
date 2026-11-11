"""Runs the PowerShell checks of bench/lib.ps1 and validates the record they emit.

Skipped unless Windows PowerShell is available (the scripts target 5.1 on Windows).
"""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import render_results as rr  # noqa: E402

# Windows PowerShell 5.1 is what the scripts target, so it is the one the tests use.
PS = shutil.which("powershell") if sys.platform == "win32" else None


@unittest.skipUnless(PS, "Windows PowerShell is not available")
class BenchLibrary(unittest.TestCase):
    def test_powershell_checks_pass_and_the_record_matches_the_schema(self):
        with tempfile.TemporaryDirectory() as tmp:
            sample = Path(tmp) / "sample.json"
            proc = subprocess.run(
                [PS, "-NoProfile", "-File", str(ROOT / "bench" / "Test-RunBench.ps1"),
                 "-EmitSample", str(sample)],
                capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            record = json.loads(sample.read_text(encoding="utf-8-sig"))
        self.assertEqual(rr.validate(record, rr.load_schema(ROOT)), [])
        self.assertEqual(record["runs"], 3)
        self.assertEqual([m["statistic"] for m in record["metrics"]], ["median", "median"])


if __name__ == "__main__":
    unittest.main()
