"""PowerShell checks: every script parses, and the shared helpers behave.

Skipped unless Windows PowerShell is available (the scripts target 5.1 on Windows).
"""
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Windows PowerShell 5.1 is what the scripts target, so it is the one the tests use.
PS = shutil.which("powershell") if sys.platform == "win32" else None

PARSE = (
    "$bad = 0; "
    "foreach ($p in $env:LAB_PS_FILES -split '\\|') { "
    "$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e); "
    "if ($e) { $bad++; foreach ($x in $e) { Write-Output ($p + ': ' + $x.Message) } } }; "
    "exit $bad"
)


def ps_files():
    skip = {".git", ".venv", "venv", "node_modules"}
    return sorted(p for p in ROOT.rglob("*.ps1") if not skip & set(p.relative_to(ROOT).parts))


@unittest.skipUnless(PS, "Windows PowerShell is not available")
class PowerShellScripts(unittest.TestCase):
    def test_there_are_scripts_to_check(self):
        names = {p.name for p in ps_files()}
        for expected in ("01-install-ollama.ps1", "stop-lab.ps1", "run-bench.ps1", "check-loopback.ps1"):
            self.assertIn(expected, names)

    def test_every_script_parses_without_errors(self):
        env = dict(os.environ, LAB_PS_FILES="|".join(str(p) for p in ps_files()))
        proc = subprocess.run([PS, "-NoProfile", "-Command", PARSE], capture_output=True,
                              text=True, env=env, timeout=120)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_shared_helpers(self):
        proc = subprocess.run([PS, "-NoProfile", "-File", str(ROOT / "tests" / "Test-Scripts.ps1")],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main()
