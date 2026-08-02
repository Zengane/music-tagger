"""Checks for the parts that are hard to eyeball: sidecar writes, windowing,
probe training.

    venv\\Scripts\\python.exe tests.py

The sidecar tests matter most — that code writes into the real library, and a
bug there silently eats hand-curated Game tags and star ratings.
"""

import json
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np

from mtag import audio as A, console, organize, probes
from mtag.sidecar import read_tags, read_taxonomy_tags, write_tags
from mtag.taxonomy import ALL_TAGS, MOOD_TAGS, SOUND_TAGS

console.init()

_failures = []


def check(cond, label):
    print(f"  {'PASS' if cond else 'FAIL'}  {label}")
    if not cond:
        _failures.append(label)


def test_sidecar():
    print("sidecar round-trip")
    tmp = Path(tempfile.mkdtemp())
    try:
        f = tmp / "song.mp3"
        f.write_bytes(b"x")
        (tmp / ".ts").mkdir()
        original = {
            "appName": "TagSpaces", "appVersion": "6.5.3",
            "description": "notes here",
            "tags": [
                {"title": "Mario-Galaxy", "type": "sidecar"},
                {"title": "5star", "type": "sidecar"},
                {"title": "⭐", "type": "sidecar"},
                {"title": "Epic", "type": "sidecar"},
                {"title": "Orchestral", "type": "sidecar"},
            ],
            "geo": {"lat": 1},
        }
        (tmp / ".ts" / "song.mp3.json").write_text(
            json.dumps(original), encoding="utf-8-sig")

        check(read_taxonomy_tags(f) == ["Epic", "Orchestral"], "reads only taxonomy tags")

        write_tags(f, ["Hype", "Tension", "Electronic"])
        after = read_tags(f)
        d = json.loads((tmp / ".ts" / "song.mp3.json").read_text(encoding="utf-8-sig"))

        check(all(t in after for t in ("Mario-Galaxy", "5star", "⭐")),
              "Game / rating / emoji tags survive a write")
        check("Epic" not in after and "Orchestral" not in after,
              "old Mood/Sound tags are replaced")
        check(set(read_taxonomy_tags(f)) == {"Hype", "Tension", "Electronic"},
              "new tags land")
        check(d["description"] == "notes here", "description preserved")
        check(d["geo"] == {"lat": 1}, "geo preserved")

        g = tmp / "new.mp3"
        g.write_bytes(b"x")
        write_tags(g, ["Chill"])
        check(read_taxonomy_tags(g) == ["Chill"], "creates a sidecar for an untagged file")

        write_tags(f, [])
        check(read_taxonomy_tags(f) == [] and "Mario-Galaxy" in read_tags(f),
              "clearing Mood/Sound leaves other tags alone")

        bad = tmp / "bad.mp3"
        bad.write_bytes(b"x")
        (tmp / ".ts" / "bad.mp3.json").write_text("{not json", encoding="utf-8")
        check(read_tags(bad) == [], "corrupt sidecar reads as empty instead of raising")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _tone_wav(path, seconds, sr=44100):
    t = np.linspace(0, seconds, int(sr * seconds), endpoint=False)
    # Rising pitch, so a window taken from the end differs from one at the start.
    y = np.sin(2 * np.pi * (220 + 400 * t / seconds) * t)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes((y * 32000).astype("<i2").tobytes())


def test_windows():
    print("whole-track windowing")
    tmp = Path(tempfile.mkdtemp())
    try:
        long_track = tmp / "long.wav"
        _tone_wav(long_track, 180)
        w = A.windows(long_track, 24000, 20.0, 12)
        check(w.shape == (9, 480000), f"180s -> 9 windows of 20s (got {w.shape})")

        # The bug that broke v1: only ever hearing the start of the track.
        check(not np.allclose(w[0], w[-1]),
              "last window differs from first (whole track is sampled)")

        huge = A.windows(long_track, 24000, 10.0, 12)
        check(huge.shape[0] == 12, "window count is capped at max_windows")

        short = tmp / "short.wav"
        _tone_wav(short, 3)
        s = A.windows(short, 24000, 20.0, 12)
        check(s.shape == (1, 480000), "short track is zero-padded to one window")
        check(np.any(s[0][:72000] != 0) and np.all(s[0][-100:] == 0),
              "padding goes at the end, audio at the start")

        check(abs(A.duration_seconds(long_track) - 180) < 0.2, "duration probe is accurate")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_probes():
    print("probe training")
    rng = np.random.default_rng(0)
    n, d = 300, 64
    W = rng.normal(size=(d, 4))
    X = rng.normal(size=(n, d))
    X /= np.linalg.norm(X, axis=1, keepdims=True)
    logits = X @ W
    Y = (logits > np.quantile(logits, 0.85, axis=0)).astype(np.int8)
    Y[:, 3] = 0
    Y[:5, 3] = 1  # too rare to train
    tags = ["a", "b", "c", "rare"]

    rep = probes.evaluate(X, Y, tags=tags)
    rows = {r["tag"]: r for r in rep["per_tag"]}
    check(rows["a"]["ap"] > 0.5, f"learns a linearly separable tag (AP {rows['a']['ap']:.2f})")
    check(rows["rare"]["trainable"] is False, "5 positives is marked untrainable")
    check(rep["summary"]["n_trainable"] == 3, "rare tag excluded from the summary")
    check(rep["summary"]["macro_recall"] > rep["summary"]["macro_precision"],
          "F-1.5 thresholds lean toward recall")

    models = probes.fit_final(X, Y, rep, tags=tags)
    check(set(models) == {"a", "b", "c"}, "only trainable tags get a final model")
    pos = [i for i in range(n) if Y[i, 0] == 1][0]
    neg = [i for i in range(n) if Y[i, 0] == 0][0]
    check(probes.predict_proba(models, "a", X[pos]) > probes.predict_proba(models, "a", X[neg]),
          "positive example scores above a negative one")


def test_organize():
    print("mood folders")
    tmp = Path(tempfile.mkdtemp())
    try:
        lib = tmp / "lib"
        for name in ("Adventure", "Build up", "chill", "SFX"):
            (lib / name).mkdir(parents=True)

        found = organize.mood_folders(lib)
        check(found["Adventure"].name == "Adventure", "exact folder name matches")
        check(found.get("Build-Up") is not None and found["Build-Up"].name == "Build up",
              "Build-Up finds the existing 'Build up' folder, not a new one")
        check(found["Chill"].name == "chill", "match is case-insensitive")
        check("Epic" not in found, "absent moods report no folder")
        check(organize.target_folder(lib, "Epic") == lib / "Epic",
              "a mood with no folder targets one named after the tag")

        # Primary mood is the highest-scoring selected mood, ignoring Sound tags.
        scores = {"Hype": {"score": 0.6}, "Tension": {"score": 0.9}, "Funky": {"score": 0.99}}
        check(organize.primary_mood(["Hype", "Tension", "Funky"], scores) == "Tension",
              "primary mood ignores Sound tags and picks the top score")
        check(organize.primary_mood(["Funky"], scores) is None, "no mood tag means no folder")

        src_dir = lib / "Adventure"
        track = src_dir / "song.mp3"
        track.write_bytes(b"audio")
        (src_dir / ".ts").mkdir()
        (src_dir / ".ts" / "song.mp3.json").write_text(
            json.dumps({"tags": [{"title": "Epic"}, {"title": "5star"}]}), encoding="utf-8-sig")

        p = organize.plan(track, lib, "Epic")
        check(p["status"] == "ok" and p["creates_folder"], "plan reports a new folder")
        check(track.exists(), "planning is a dry run")

        res = organize.apply(p)
        moved = lib / "Epic" / "song.mp3"
        check(res["moved"] and moved.exists() and not track.exists(), "file moves")
        check((lib / "Epic" / ".ts" / "song.mp3.json").exists(), "sidecar follows the file")
        check(read_tags(moved) == ["Epic", "5star"], "tags survive the move")
        check(not (src_dir / ".ts").exists(), "empty .ts folder is cleaned up")
        check(src_dir.exists(), "the source mood folder itself is left alone")

        check(organize.plan(moved, lib, "Epic")["status"] == "already-there",
              "a file already in place is a no-op")

        clash = lib / "Adventure" / "song.mp3"
        clash.write_bytes(b"different audio")
        cp = organize.plan(clash, lib, "Epic")
        check(cp["status"] == "collision", "a name clash is refused")
        check(organize.apply(cp)["moved"] is False, "refused moves do nothing")
        check(moved.read_bytes() == b"audio", "the existing file is not overwritten")
        check(clash.exists(), "the source file stays put on a collision")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_taxonomy_matches_library():
    print("taxonomy vs TagSpaces tag library")
    lib = Path(r"H:\Media Browser\Mega Music Pack\Mega Music Pack tag library.json")
    if not lib.exists():
        print("  SKIP  tag library not reachable")
        return
    groups = {g["title"]: [c["title"] for c in g["children"]]
              for g in json.loads(lib.read_text(encoding="utf-8-sig"))["tagGroups"]}
    check(groups.get("Mood") == MOOD_TAGS, "Mood group matches taxonomy.py")
    check(groups.get("Sound") == SOUND_TAGS, "Sound group matches taxonomy.py")
    # Ratings and Emojis are the user's own; the tagger must never assign them.
    others = set(groups.get("Ratings", [])) | set(groups.get("Emojis 🎨", [])) | set(groups.get("Game", []))
    check(not (others & set(ALL_TAGS)),
          "no rating, emoji or Game tag is in the tagger's vocabulary")


def test_fusion_text_slice():
    print("fusion text slice")
    from mtag.encoders import FusionEncoder
    from mtag.model import text_block

    f = FusionEncoder()
    check(f.part_names == ("muq-mulan", "muq", "clap-music"), "MERT is excluded from the fusion")
    check(f.has_text, "fusion reports a text tower")

    # Zero-shot must read the text-aligned part's mean block, not the first
    # half of the concatenation — those are different once parts are stacked.
    f.part_dims = {"muq-mulan": 1024, "muq": 2048, "clap-music": 1024}
    check(f.text_slice(4096) == (0, 512), "slice is MuQ-MuLan's mean block, not (0, 2048)")

    g = FusionEncoder(parts=("muq", "muq-mulan"))
    g.part_dims = {"muq": 2048, "muq-mulan": 1024}
    check(g.text_slice(3072) == (2048, 2560), "slice follows the part's offset in the concat")

    h = FusionEncoder(parts=("muq",))
    h.part_dims = {"muq": 2048}
    check(h.text_slice(2048) is None, "a fusion with no text tower has no slice")

    X = np.tile(np.arange(4096, dtype=np.float32), (3, 1))
    blk = text_block(X, (0, 512))
    check(blk.shape == (3, 512), "text_block returns just those columns")
    check(np.allclose(np.linalg.norm(blk, axis=1), 1.0), "text_block renormalises")


def test_ffmpeg():
    print("environment")
    ok = subprocess.run(["ffmpeg", "-version"], capture_output=True).returncode == 0
    check(ok, "ffmpeg on PATH")
    import torch
    check(torch.cuda.is_available(), "torch sees the GPU (v1 silently ran on CPU)")


if __name__ == "__main__":
    for t in (test_ffmpeg, test_sidecar, test_taxonomy_matches_library,
              test_windows, test_organize, test_fusion_text_slice, test_probes):
        t()
    print()
    if _failures:
        print(f"{len(_failures)} FAILED: " + "; ".join(_failures))
        raise SystemExit(1)
    print("all checks passed")
