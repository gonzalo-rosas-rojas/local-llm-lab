"""What the tests that run PowerShell share: which PowerShell they use."""
import shutil
import sys

# Windows PowerShell 5.1 is what the scripts target, so it is the one the tests use.
PS = shutil.which("powershell") if sys.platform == "win32" else None
