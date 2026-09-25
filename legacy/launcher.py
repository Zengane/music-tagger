"""Small executable entry point that launches the project's managed runtime."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from tkinter import messagebox


def project_root() -> Path:
    here = Path(sys.executable if getattr(sys, "frozen", False) else __file__).resolve().parent
    if (here / "desktop.py").exists():
        return here
    return here.parent


def main() -> None:
    root = project_root()
    python = root / "venv" / "Scripts" / "pythonw.exe"
    desktop = root / "desktop.py"
    if not python.exists() or not desktop.exists():
        messagebox.showerror(
            "Music Tagger",
            "The Music Tagger project or its Python environment was not found.\n\n"
            f"Expected: {root}",
        )
        raise SystemExit(1)
    subprocess.Popen([str(python), str(desktop)], cwd=str(root), creationflags=0x08000000)


if __name__ == "__main__":
    main()
