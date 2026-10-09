r"""Naming tracks from tags, on throwaway files. Run: venv\Scripts\python.exe tests_namefix.py"""
import json, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

from mtag import audio as A, namefix
from mtag.sidecar import sidecar_path

tmp = Path(tempfile.mkdtemp(prefix="namefix-"))
names = ["A Past Fraught With Sorrow", "Who's Next? / Ending", "Same", "Same", "Four", "Five"]
for i, n in enumerate(names, start=1):
    f = tmp / f"abc123-{i}_-_Miitopia.m4a"
    subprocess.run([A.FFMPEG, "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "0.2",
                    "-metadata", "title=Miitopia", "-metadata", f"artist={n}", "-metadata", f"track={i}/10",
                    str(f)], check=True)
side = sidecar_path(tmp / "abc123-1_-_Miitopia.m4a")
side.parent.mkdir()
side.write_text(json.dumps({"tags": [{"title": "Chill"}]}), encoding="utf-8")

entries = namefix.plan(tmp)
assert all(e["field"] == "artist" for e in entries), entries
dst = sorted(Path(e["dst"]).name for e in entries)
assert dst == ["01 - A Past Fraught With Sorrow.m4a", "02 - Who's Next- - Ending.m4a",
               "03 - Same.m4a", "04 - Same.m4a", "05 - Four.m4a", "06 - Five.m4a"], dst   # width 2 for 10 tracks

done = [namefix.apply(e) for e in entries]
assert all(d["renamed"] for d in done)
assert sidecar_path(tmp / "01 - A Past Fraught With Sorrow.m4a").exists() and not side.exists()
assert all(e["status"] == "same" for e in namefix.plan(tmp)), "second run must change nothing"
print("ok")
