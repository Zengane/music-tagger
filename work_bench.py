"""A benchmark of SFX families, derived from the library's own filenames.

Names here are CamelCase with a trailing counter: BabyCryWhimper, FlyBy 83,
Absorb 81. The leading word is what the file *is*, so files sharing it are a
family. Derived rather than hand-listed, so it cannot be tuned to flatter a
particular model.
"""
import json, random, re, sys
from collections import Counter, defaultdict
from pathlib import Path
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(r"<your library folder>\SFX")
EXTS = {".wav", ".mp3", ".flac", ".ogg", ".m4a", ".aiff", ".aif"}
STOP = {"sfx", "the", "and", "a", "of", "bpm", "short", "long", "small", "big"}

def tokens(stem):
    s = re.sub(r"^\d+__[a-z0-9_\-]+__", " ", stem)          # freesound ids
    s = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", s)               # camelCase
    s = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", " ", s)          # ACRONYMWord
    s = re.sub(r"[^A-Za-z]+", " ", s)
    return [w for w in s.lower().split() if len(w) > 2 and w not in STOP]

files = [p for p in ROOT.rglob("*") if p.suffix.lower() in EXTS and ".ts" not in p.parts]
print(f"{len(files)} SFX files")

# The head word names the thing; the rest describes it.
heads = defaultdict(list)
for p in files:
    t = tokens(p.stem)
    if t:
        heads[t[0]].append(p)

fams = {h: ps for h, ps in heads.items() if len(ps) >= 8}
print(f"{len(fams)} head words with 8+ files\n")

random.seed(7)
bench = {}
for h, ps in fams.items():
    random.shuffle(ps)
    bench[h] = [str(x) for x in ps[:12]]

top = sorted(bench.items(), key=lambda kv: -len(kv[1]))
for h, ps in top[:24]:
    print(f"  {h:16s} {len(ps)}")
print(f"  … {len(top) - 24} more" if len(top) > 24 else "")

total = sum(len(v) for v in bench.values())
print(f"\n{len(bench)} families, {total} files")
Path("work").mkdir(exist_ok=True)
Path("work/sfx_bench.json").write_text(json.dumps(bench, indent=1), encoding="utf-8")
