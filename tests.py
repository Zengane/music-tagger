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

from mtag import audio as A, console, probes
from mtag.sidecar import read_tags, read_taxonomy_tags, write_tags

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


def test_ffmpeg():
    print("environment")
    ok = subprocess.run(["ffmpeg", "-version"], capture_output=True).returncode == 0
    check(ok, "ffmpeg on PATH")
    import torch
    check(torch.cuda.is_available(), "torch sees the GPU (v1 silently ran on CPU)")


if __name__ == "__main__":
    for t in (test_ffmpeg, test_sidecar, test_windows, test_probes):
        t()
    print()
    if _failures:
        print(f"{len(_failures)} FAILED: " + "; ".join(_failures))
        raise SystemExit(1)
    print("all checks passed")
