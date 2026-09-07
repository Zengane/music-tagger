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
from mtag.sidecar import read_sfx_tags, read_tags, read_taxonomy_tags, write_tags
from mtag.taxonomy import ALL_TAGS, AUDIO_EXTS, MOOD_TAGS, SOUND_TAGS

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
    lib = Path(r"<your library folder>\Mega Music Pack tag library.json")
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

    # Game tags may differ from the library where a name was renamed by hand;
    # every such difference has to be spelled out in GAME_ALIASES.
    from mtag.taxonomy import GAME_ALIASES, GAME_TAGS
    lib_games = set(groups.get("Game", []))
    unexplained = (lib_games - set(GAME_TAGS)) - set(GAME_ALIASES)
    check(not unexplained, f"every library game tag is known or aliased ({unexplained or 'none left over'})")
    check(set(GAME_ALIASES.values()) <= set(GAME_TAGS), "aliases resolve to real game tags")


def test_skipping():
    print("skipping renders and SFX")
    tmp = Path(tempfile.mkdtemp())
    try:
        # Names must differ by more than case: Windows would merge them otherwise.
        for rel in ("Chill/song.mp3",
                    "Chill/theme Audio Extracted.wav",
                    "Chill/other AUDIO EXTRACTED.wav",
                    "SFX/Drone/drone_1.wav",
                    "sfx/hit.wav"):
            p = tmp / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b"x")

        found = {f.name for f in A.find_audio(tmp, AUDIO_EXTS)}
        check(found == {"song.mp3"}, f"only the real track survives (got {sorted(found)})")

        allf = A.find_audio(tmp, AUDIO_EXTS, skip_dirs=(), skip_patterns=())
        check(len(allf) == 5, "opting out of skipping returns everything")

        # Rendering out audio for Audition drops the result next to the original;
        # those renders must never be tagged or counted as new music.
        check(not any("audio extracted" in f.name.lower() for f in A.find_audio(tmp, AUDIO_EXTS)),
              "the match is case-insensitive")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_search_and_sfx():
    print("boolean search and SFX tags")
    from mtag import search
    tmp = Path(tempfile.mkdtemp())
    try:
        f = tmp / "Celeste" / "01 - Mountain.mp3"
        f.parent.mkdir(parents=True)
        f.write_bytes(b"audio")
        write_tags(f, ["Epic", "Orchestral", "Ambience", "Whoosh"], game="Celeste")
        check(search.matches(f, "tag:Epic tag:Orchestral game:Celeste"),
              "combined tag search uses AND semantics")
        check(not search.matches(f, "tag:Epic tag:Chill"),
              "a missing tag rejects the combined search")
        check(search.matches(f, 'name:"01 - Mountain"'),
              "quoted filename search works")
        check(search.matches(f, '+Epic +Orchestral'),
              "plus-prefixed tags require all matches")
        check(search.matches(f, 'mountin'),
              "bare search tolerates a small typo")
        check(not search.matches(f, '-Epic'),
              "minus-prefixed tags are excluded")
        check(read_sfx_tags(f) == ["Ambience", "Whoosh"],
              "SFX tags round-trip separately from music tags")
        check(read_taxonomy_tags(f) == ["Epic", "Orchestral"],
              "SFX tags do not enter the music taxonomy")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_waveform():
    print("waveform preview")
    tmp = Path(tempfile.mkdtemp())
    try:
        tone = tmp / "tone.wav"
        _tone_wav(tone, 2)
        preview = A.waveform(tone, 96)
        check(1.8 < preview["duration"] < 2.2, "waveform reports duration")
        check(len(preview["peaks"]) == 96, "waveform is downsampled to requested points")
        check(max(preview["peaks"]) > 0.8, "waveform contains audio peaks")
        clip = tmp / "selection.wav"
        A.export_clip(tone, .25, .75, clip)
        check(clip.exists() and .4 < A.duration_seconds(clip) < .9,
              "selected waveform range exports as a short audio clip")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_tag_aliases():
    print("tag aliases")
    from mtag import gametag
    tmp = Path(tempfile.mkdtemp())
    try:
        f = tmp / "song.mp3"
        f.write_bytes(b"x")
        (tmp / ".ts").mkdir()
        (tmp / ".ts" / "song.mp3.json").write_text(json.dumps({"tags": [
            {"title": "Jazz"}, {"title": "Bombastic"}, {"title": "Sims"},
            {"title": "Jet-Set-Radio"},
        ]}), encoding="utf-8-sig")

        # The bug this fixes: "Jazz" isn't in the library, so the file read as
        # untagged and never trained.
        check(read_taxonomy_tags(f) == ["Jazzy", "Bombastic-Heavy"],
              "misspelled Mood/Sound tags resolve to real ones")
        check("Jet-Set-Radio-or-Bomb-Rush-Cyberfunk" in read_tags(f),
              "renamed game tags resolve too")
        # The apostrophe form is the stale one here: TagSpaces wouldn't match it,
        # so all 44 files use "Penny-Big-Breakaway" and the library's entry doesn't.
        check(gametag.canonical("Penny's-Big-Breakaway") == "Penny-Big-Breakaway",
              "the apostrophe-free Penny spelling is canonical")
        check("Jazz" in read_tags(f, raw=True), "raw=True still shows what's on disk")

        write_tags(f, ["Jazzy", "Chill"])
        after = read_tags(f, raw=True)
        check("Jazz" not in after, "saving clears the misspelled tag rather than keeping both")
        check(sorted(t for t in after if t in ("Jazzy", "Chill")) == ["Chill", "Jazzy"],
              "the corrected tags are written")
        check("Sims" in after, "unrelated tags are still preserved")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_gametag():
    print("game detection")
    from mtag import gametag

    cases = [
        ("Freezeflame Galaxy (Ice) -  Super Mario Galaxy.m4a", "Mario-Galaxy"),
        ("1. Trailer Theme - Super Mario Odyssey OST.mp3", "Mario-Odyssey"),
        ("Shin Megami Tensei IV OST - K's Tavern.mp3", "SMT4"),
        ("Clock Town First Day - The Legend of Zelda Majora's Mask OST.mp3", "N64-Zelda"),
        ("Dizzy Sim- Sims Hot Date.mp3", "Sims"),
        ("🎼C C Generals Zero Hour Soundtrack ｜ China.mp3", "Command-and-Conquer"),
        ("- ブルーアーカイブ Blue Archive OST 3. Mischievous Step.mp3", "Blue-Archive"),
        ("Battania Theme (Mount & Blade II Bannerlord Soundtrack).mp3", "Mount-&-Blade"),
        ("05 Sneakman.mp3", None),
        ("A Few Screws Loose.mp3", None),
    ]
    for name, want in cases:
        got = gametag.detect(Path("/lib/Chill") / name)
        check(got == want, f"{name[:44]!r} -> {got}")

    # Longest phrase wins, or "Super Mario Galaxy" would match a bare "Mario".
    check(gametag.from_text("Super Mario Galaxy 2 Soundtrack") == "Mario-Galaxy",
          "longer phrases are matched first")

    tmp = Path(tempfile.mkdtemp())
    try:
        lib = tmp / "lib"
        deep = lib / "Chill" / "A Hat in Time OST"
        deep.mkdir(parents=True)
        track = deep / "01 Main Theme.mp3"
        track.write_bytes(b"x")
        tag, src, is_new = gametag.detect_detail(track, lib)
        check(tag == "A-Hat-In-Time", "falls back to the containing folder")
        check("folder" in (src or ""), "and reports that it came from a folder")
        check(is_new is False, "a known game is not flagged as new")

        flat = lib / "Chill" / "01 Main Theme.mp3"
        flat.write_bytes(b"x")
        check(gametag.detect(flat, lib) is None,
              "a mood folder is not treated as a game name")

        # Most of a fresh drop is games the tag library hasn't heard of; the
        # folder names them, but they're flagged so nothing invents a tag alone.
        drop = lib / "Untagged" / "Bayonetta" / "DISC 3"
        drop.mkdir(parents=True)
        unknown = drop / "07 Battle.mp3"
        unknown.write_bytes(b"x")
        tag, src, is_new = gametag.detect_detail(unknown, lib)
        check((tag, is_new) == ("Bayonetta", True),
              f"an unknown game is proposed from its folder (got {tag!r}, new={is_new})")
        check(gametag.detect(unknown, lib) is None,
              "detect() stays limited to known tags")

        # The drop folder names the game; the subfolder a track sits in doesn't.
        bside = lib / "Untagged" / "Wario World" / "B Side"
        bside.mkdir(parents=True)
        t2 = bside / "03 Greenhorn Forest.mp3"
        t2.write_bytes(b"x")
        tag, src, is_new = gametag.detect_detail(t2, lib)
        check(tag == "Wario-World", f"the outermost folder names it, not 'B Side' (got {tag!r})")

        # A folder name outranks the filename, since a drop is named per game.
        conflict = lib / "Untagged" / "Pikuniku"
        conflict.mkdir(parents=True)
        t3 = conflict / "Super Mario Galaxy style remix.mp3"
        t3.write_bytes(b"x")
        check(gametag.detect(t3, lib) == "Pikuniku",
              "a known folder beats a known filename")

        # ...but a known filename still beats a *guessed* folder name, so a
        # compilation folder doesn't swallow the tracks inside it.
        comp = lib / "Untagged" / "JimmyHere music"
        comp.mkdir(parents=True)
        t4 = comp / "Super Mario Galaxy - Gusty Garden.mp3"
        t4.write_bytes(b"x")
        check(gametag.detect(t4, lib) == "Mario-Galaxy",
              "a known filename beats an unknown folder")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    for folder, want in [
        ("Wario World OST", "Wario-World"),
        ("Best Mario Kart Tracks", "Mario-Kart"),
        ("Terraria Soundtrack (1 4 4)", "Terraria"),
        ("The Legend of Zelda Breath of the Wild Soundtrack",
         "Legend-Of-Zelda-Breath-Of-The-Wild"),
        ("VA-11 Hall-A", "VA-11-Hall-A"),
        ("TF2", "TF2"),
        ("OST", None),
        # No apostrophes: TagSpaces wouldn't match "Penny's-Big-Breakaway".
        ("Penny's Big Breakaway OST", "Pennys-Big-Breakaway"),
    ]:
        got = gametag.tag_from_folder(folder)
        check(got == want, f"{folder!r} -> {got!r}")

    # Breath of the Wild used to match "legend of zelda" and land 123 tracks
    # on the N64-Zelda tag.
    check(gametag.from_text("The Legend of Zelda Breath of the Wild") is None,
          "Breath of the Wild does not match N64-Zelda")
    check(gametag.from_text("Zelda Ocarina of Time OST") == "N64-Zelda",
          "Ocarina of Time still does")


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
              test_skipping, test_search_and_sfx, test_waveform,
              test_tag_aliases, test_gametag, test_windows, test_organize,
              test_fusion_text_slice, test_probes):
        t()
    print()
    if _failures:
        print(f"{len(_failures)} FAILED: " + "; ".join(_failures))
        raise SystemExit(1)
    print("all checks passed")
