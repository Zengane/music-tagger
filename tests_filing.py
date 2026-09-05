r"""The filing job, end to end, on a throwaway library.

Moving files is the one thing here that cannot be undone with a keystroke, so
the cases that matter are the refusals: a name clash must leave both files
alone, and the plan pass must move nothing at all. Run it with:

    venv\Scripts\python.exe tests_filing.py
"""
import json, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(r"C:\Users\simsi\music-tagger-v2")
sys.path.insert(0, str(ROOT))
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

tmp = Path(tempfile.mkdtemp(prefix="filingtest-"))
lib = tmp / "library"
(lib / "Untagged").mkdir(parents=True)
(lib / "Chill").mkdir()
(lib / "Untagged" / ".ts").mkdir()

track = lib / "Untagged" / "song one.mp3"
track.write_bytes(b"not really audio")
side = lib / "Untagged" / ".ts" / "song one.mp3.json"
side.write_text(json.dumps({"tags": [{"title": "Chill"}]}), encoding="utf-8")

# A second one whose destination folder does not exist yet.
t2 = lib / "Untagged" / "song two.mp3"
t2.write_bytes(b"nope")

# A third that would land on an existing file: must be refused, not overwritten.
t3 = lib / "Untagged" / "clash.mp3"
t3.write_bytes(b"new")
(lib / "Chill" / "clash.mp3").write_bytes(b"ORIGINAL")

# A map that already places these tracks, so the move has something to carry.
mapdoc = tmp / "soundmap.json"
mapdoc.write_text(json.dumps({"version": 1, "points": {
    str(track): [0.5, -0.25],
    str(t2):    [0.1, 0.9],
    str(t3):    [0.0, 0.0],
}}), encoding="utf-8")

moves = tmp / "moves.txt"
moves.write_text(
    f"Chill\t{track}\nEpic\t{t2}\nChill\t{t3}\n", encoding="utf-8")

def run(mode):
    p = subprocess.run(
        [str(ROOT / "venv" / "Scripts" / "python.exe"), str(ROOT / "organize_job.py"),
         mode, "--library", str(lib), "--moves-from", str(moves)],
        capture_output=True, text=True, encoding="utf-8", cwd=str(ROOT))
    out = []
    for line in p.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            out.append(json.loads(line))
    return out, p.returncode

def check(label, cond, detail=""):
    print(("  ok    " if cond else "  FAIL  ") + label + (f" — {detail}" if detail and not cond else ""))
    return cond

fails = 0
print("\nfiling, end to end")

plan, code = run("--plan")
statuses = {e["src"]: e["status"] for e in plan if e["event"] == "plan"}
fails += not check("the plan runs", code == 0)
fails += not check("a clean move is ok", statuses.get(str(track)) == "ok", str(statuses))
fails += not check("a missing destination folder is still ok", statuses.get(str(t2)) == "ok")
fails += not check("a name clash is a collision", statuses.get(str(t3)) == "collision")
fails += not check("the plan moved nothing", track.exists() and side.exists())

applied, code = run("--apply")
done = [e for e in applied if e["event"] == "done"][-1]
fails += not check("the apply runs", code == 0)
fails += not check("two moved, one skipped",
                   done["moved"] == 2 and done["skipped"] == 1, str(done))
fails += not check("the track is in its mood folder", (lib / "Chill" / "song one.mp3").exists())
fails += not check("the sidecar came with it",
                   (lib / "Chill" / ".ts" / "song one.mp3.json").exists())
fails += not check("the old copy is gone", not track.exists())
fails += not check("a missing folder was created", (lib / "Epic" / "song two.mp3").exists())
fails += not check("the clash was left alone",
                   (lib / "Chill" / "clash.mp3").read_bytes() == b"ORIGINAL")
fails += not check("and its file stayed put", t3.exists())

# The map's own coordinates have to follow the files.
#
# They did not, and nothing said so: the app just saw those tracks as unplaced,
# quietly fell back to the layout built from measured audio, and the map came
# back looking like a different feature. 1649 points were orphaned in one run.
sys.path.insert(0, str(ROOT))
from mtag import organize
carried = organize.rekey_soundmap(
    [(track, lib / "Chill" / "song one.mp3"), (t2, lib / "Epic" / "song two.mp3")],
    path=mapdoc)
points = json.loads(mapdoc.read_text(encoding="utf-8"))["points"]
fails += not check("two points were carried over", carried == 2, str(carried))
fails += not check("the moved track kept its place",
                   points.get(str(lib / "Chill" / "song one.mp3")) == [0.5, -0.25])
fails += not check("the old key is gone", str(track) not in points)
fails += not check("the file that never moved kept its own key", str(t3) in points)
fails += not check("nothing else was invented", len(points) == 3, str(len(points)))

shutil.rmtree(tmp, ignore_errors=True)
print("\n" + ("all checks passed" if fails == 0 else f"{fails} checks failed"))
sys.exit(1 if fails else 0)
