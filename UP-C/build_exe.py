"""Build the portable Windows application in release/ (run in .venv)."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent
subprocess.run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--onefile", "--windowed",
    "--name", "应急系统", "--distpath", str(root / "release"), "--workpath", str(root / ".build"),
    "--specpath", str(root / ".build"), "--icon", str(root / "assets/emergency.ico"),
    "--add-data", str(root / "assets") + ";assets", str(root / "emergency_system.py")], cwd=root, check=True)
