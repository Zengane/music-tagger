r"""Assemble a shareable copy of Music Tagger.

    venv\Scripts\python.exe make_release.py

Produces `dist\MusicTagger\` and a zip beside it. The app reads everything
relative to its own .exe, so the release is a folder you unzip anywhere — there
is nothing to register and nothing to uninstall.

What goes in, and what deliberately does not:

  * `MusicTagger.exe` and the Python that supports it. The jobs are read from
    source at run time, so they ship as .py files rather than being frozen.
  * `model\tagger.pkl` — the trained tagger. It is the useful part: without it
    the AI has nothing to say, and retraining it needs a labelled library.
  * `tag_library.json` with the Mood, Sound and SFX vocabularies, and with the
    Game group emptied. Game tags are one person's collection — Bayonetta,
    Yosumin, VA-11 Hall-A — and mean nothing to anyone else. The group stays so
    the app still has somewhere to put them; it just starts empty.
  * No library, no caches, no preferences, no library paths. Those are personal
    and some of them are gigabytes.

The Python environment is not bundled. Torch alone is 3.6 GB, which is neither
shareable on GitHub nor something to unzip. `setup.bat` builds it on the user's
machine instead, and the app works without it for everything except the AI.
"""
from __future__ import annotations

import json
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "dist" / "MusicTagger"

# Everything the app or its jobs import at run time.
FILES = [
    "MusicTagger.exe",
    "tag_job.py",
    "sfx_job.py",
    "map_job.py",
    "sfx_map_job.py",
    "organize_job.py",
    "import_folder_job.py",
    "sfx_split_job.py",
    "requirements.txt",
]
DIRS = ["mtag"]
MODEL = ["tagger.pkl"]


def base_tag_library(src: Path) -> dict:
    """The shipped vocabulary: everything except one person's games."""
    doc = json.loads(src.read_text(encoding="utf-8-sig"))
    key = "tagGroups" if "tagGroups" in doc else "groups"
    for group in doc[key]:
        name = (group.get("title") or group.get("name") or "").strip().lower()
        if name == "game":
            if "tags" in group:
                group["tags"] = []
            if "children" in group:
                group["children"] = []
    return doc


def main() -> int:
    exe = ROOT / "MusicTagger.exe"
    if not exe.exists():
        print("Build MusicTagger.exe first (build.bat).")
        return 1

    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    missing = []
    for name in FILES:
        src = ROOT / name
        if src.exists():
            shutil.copy2(src, OUT / name)
        else:
            missing.append(name)

    for name in DIRS:
        src = ROOT / name
        if src.is_dir():
            shutil.copytree(src, OUT / name,
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        else:
            missing.append(name + "/")

    (OUT / "model").mkdir(exist_ok=True)
    for name in MODEL:
        src = ROOT / "model" / name
        if src.exists():
            shutil.copy2(src, OUT / "model" / name)
        else:
            missing.append(f"model/{name}")

    lib = ROOT / "tag_library.json"
    if lib.exists():
        (OUT / "tag_library.json").write_text(
            json.dumps(base_tag_library(lib), ensure_ascii=False, indent=1),
            encoding="utf-8")
    else:
        missing.append("tag_library.json")

    (OUT / "setup.bat").write_text(SETUP_BAT, encoding="utf-8")
    (OUT / "README.txt").write_text(README, encoding="utf-8")

    if missing:
        print("missing, not packaged:")
        for m in missing:
            print("   ", m)

    zip_path = ROOT / "dist" / "MusicTagger.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(OUT.rglob("*")):
            if p.is_file():
                z.write(p, p.relative_to(OUT.parent))

    total = sum(p.stat().st_size for p in OUT.rglob("*") if p.is_file())
    print(f"\n{OUT}")
    print(f"  {sum(1 for p in OUT.rglob('*') if p.is_file())} files, {total/1e6:.1f} MB")
    print(f"{zip_path}")
    print(f"  {zip_path.stat().st_size/1e6:.1f} MB")

    # A tag library that still carried someone's game list would be the one
    # mistake worth catching here, because nobody would notice it downstream.
    shipped = json.loads((OUT / "tag_library.json").read_text(encoding="utf-8"))
    key = "tagGroups" if "tagGroups" in shipped else "groups"
    for g in shipped[key]:
        name = (g.get("title") or g.get("name") or "")
        n = len(g.get("tags") or g.get("children") or [])
        if name.strip().lower() == "game" and n:
            print(f"\nERROR: {n} game tags are still in the shipped library")
            return 1
    print("\nno game tags in the shipped vocabulary")
    return 0


SETUP_BAT = r"""@echo off
cd /d "%~dp0"
title Music Tagger setup

echo Music Tagger needs a Python environment for the AI features:
echo   tagging, the sound maps, filing, and importing folders.
echo Browsing, playing and tagging by hand work without it.
echo.

where python >nul 2>nul
if errorlevel 1 (
    echo Python was not found. Install Python 3.12 or newer from python.org,
    echo tick "Add python.exe to PATH" during setup, then run this again.
    pause & exit /b 1
)

where ffmpeg >nul 2>nul
if errorlevel 1 (
    echo.
    echo NOTE: ffmpeg was not found either. Without it, some audio formats will
    echo not play and waveforms will not be drawn. Get it from ffmpeg.org and
    echo put ffmpeg.exe and ffprobe.exe on your PATH.
    echo.
)

if not exist venv (
    echo Creating the environment. This takes a minute.
    python -m venv venv
    if errorlevel 1 ( echo Could not create venv. & pause & exit /b 1 )
)

echo Installing packages. This downloads a few GB and takes a while.
venv\Scripts\python.exe -m pip install --upgrade pip
venv\Scripts\python.exe -m pip install -r requirements.txt
if errorlevel 1 ( echo Install failed. & pause & exit /b 1 )

echo.
echo Done. Start MusicTagger.exe.
pause
"""

README = r"""Music Tagger
============

Unzip anywhere and run MusicTagger.exe. Nothing is installed and nothing is
written outside this folder — to remove it, delete the folder.

First run
---------

1.  Start MusicTagger.exe.
2.  Press + in the sidebar and point it at a folder of audio.

That is enough to browse, play, tag by hand, and send clips to Premiere.

For the AI features
-------------------

Tagging, the sound maps, filing and folder imports run Python. Run setup.bat
once. It needs Python 3.12+ on your PATH and downloads a few GB of packages.

ffmpeg is also needed for waveforms and for anything that is not a plain
16-bit WAV, MP3, OGG or FLAC. Put ffmpeg.exe and ffprobe.exe on your PATH.

What is in the box
------------------

model\tagger.pkl   A tagger trained on a real, hand-tagged library. It scores
                   a track against 33 mood and sound tags, and only applies the
                   ones whose accuracy was measured to be good enough — the
                   rest are offered as suggestions.

tag_library.json   The Mood, Sound and SFX vocabularies. The Game group is
                   empty on purpose: game tags belong to whoever made the
                   library, and yours will be your own.

Your tags are written into TagSpaces sidecars (a .ts folder beside the audio),
so they travel with the files and other tools can read them.

Nothing is written to your library until you press Save.
"""


if __name__ == "__main__":
    sys.exit(main())
