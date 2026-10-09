"""The downloader, offline.

Names: the game or album a playlist title names, and each track's title,
artist and number (mtag/downloads.py). Measured on the titles of the test
playlist the owner gave (Lethal League Blaze OST, 20 videos) and on the
patterns seen in game music uploads.

The run: download_job.py against a stand-in yt-dlp that makes a short tone
with ffmpeg instead of fetching anything. It checks tags, cover art, the
folder, that a second run skips what is there, and that nothing is ever
overwritten. Needs ffmpeg; no network.

    venv\\Scripts\\python.exe tests_download.py
"""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import download_job
from mtag.downloads import (clean_name, game_in_title, guess_collection, guess_tracks,
                            parse_track, render_template, safe_filename, split_disc)

LLB = [
    "AAron EVO - Beverly Chills [Lethal League Blaze OST]",
    "B. Bravo & Lean Rock - Shred [Lethal League Blaze OST]",
    "Bignic - Ruiner [Lethal League Blaze OST]",
    "Bignic - Scream [Lethal League Blaze OST]",
    "D Fast - Jungaaaa [Lethal League Blaze OST]",
    "Hideki Naganuma - AIN'T NOTHIN' LIKE A FUNKY BEAT [Lethal League Blaze OST]",
    "The Sleepers RecordZ ft. Nasty Den - Nasty Lovers [Lethal League Blaze OST]",
    "zeroSCAR - X [Lethal League Blaze OST]",
]


class NameTests(unittest.TestCase):
    def test_playlist_names(self):
        cases = {
            "Lethal League Blaze OST": "Lethal League Blaze",
            "Super Mario Galaxy - Original Soundtrack [Full Album]": "Super Mario Galaxy",
            "Album - Hades (Original Soundtrack)": "Hades",
            "Celeste Original Soundtrack": "Celeste",
            "Celeste Original Game SoundTrack": "Celeste",
            "Undertale OST": "Undertale",
            "NieR:Automata Original Soundtrack": "NieR:Automata",
            "Persona 5 OST (Complete)": "Persona 5",
            "Kirby Super Star Music": "Kirby Super Star",
            "DOOM (2016) OST": "DOOM (2016)",
            "Hollow Knight Soundtrack 2017": "Hollow Knight",
            "Pokémon X & Y - Complete Soundtrack (Disc 2)": "Pokémon X & Y",
            "FIFA 2002 OST": "FIFA 2002",
            "Original Sin 2 Soundtrack": "Original Sin 2",
        }
        for title, want in cases.items():
            self.assertEqual(clean_name(title), want, title)

    def test_disc(self):
        self.assertEqual(split_disc("Pokémon X & Y OST (Disc 2)"), ("Pokémon X & Y OST", 2))
        self.assertEqual(split_disc("Xenoblade CD 3")[1], 3)
        self.assertEqual(split_disc("Abcd 2")[1], 0)

    def test_collection(self):
        g = guess_collection("Lethal League Blaze OST", LLB, "Modern")
        self.assertEqual((g["name"], g["category"]), ("Lethal League Blaze", "game"))
        # A playlist named for nothing: the videos name the game.
        g = guess_collection("OST", ["Celeste OST - Prologue", "Celeste OST - First Steps",
                                     "Celeste OST - Resurrections"])
        self.assertEqual(g["name"], "Celeste")
        # Not game music.
        g = guess_collection("Abbey Road (Remastered)", ["Come Together", "Something"], "The Beatles - Topic")
        self.assertEqual((g["category"], g["album_artist"]), ("music", "The Beatles"))

    def test_single_video_names_its_game(self):
        self.assertEqual(game_in_title("Bignic - Ruiner [Lethal League Blaze OST]"), "Lethal League Blaze")
        self.assertEqual(game_in_title("Just a song"), "")
        g = guess_collection("Bignic - Ruiner [Lethal League Blaze OST]", ["Bignic - Ruiner [Lethal League Blaze OST]"])
        self.assertEqual(g["name"], "Lethal League Blaze")

    def test_playlist_tracks(self):
        entries = [{"title": t} for t in LLB]
        got = guess_tracks(entries, "Lethal League Blaze")
        self.assertEqual([(p["track"], p["artist"], p["title"]) for p in got[:3]], [
            (1, "AAron EVO", "Beverly Chills"), (2, "B. Bravo & Lean Rock", "Shred"), (3, "Bignic", "Ruiner")])
        self.assertEqual(got[5]["title"], "AIN'T NOTHIN' LIKE A FUNKY BEAT")
        self.assertEqual(got[7]["title"], "X")
        self.assertTrue(all("Lethal" not in p["title"] and "OST" not in p["title"] for p in got))

    def test_track_patterns(self):
        cases = [
            ("Super Mario Galaxy OST - Gusty Garden Galaxy", "Super Mario Galaxy", (0, "", "Gusty Garden Galaxy")),
            ("Gusty Garden Galaxy - Super Mario Galaxy OST", "Super Mario Galaxy", (0, "", "Gusty Garden Galaxy")),
            ("01. Main Theme (HQ)", "X", (1, "", "Main Theme")),
            ("Track 12 - Boss Battle", "Y", (12, "", "Boss Battle")),
            ("Celeste OST - 03 - Resurrections", "Celeste", (3, "", "Resurrections")),
            ("Hades - Good Riddance (Official Audio)", "Hades", (0, "", "Good Riddance")),
            ("Lena Raine - Resurrections", "Celeste", (0, "Lena Raine", "Resurrections")),
        ]
        for title, game, (track, artist, name) in cases:
            p = parse_track(title, game)
            self.assertEqual((p["track"], p["artist"], p["title"]), (track, artist, name), title)
        p = parse_track("1-05 Field Theme", "Z")
        self.assertEqual((p["disc"], p["track"], p["title"]), (1, 5, "Field Theme"))
        self.assertEqual(parse_track("Main Theme - Reprise", "Z", pattern="title")["title"], "Main Theme - Reprise")
        p = parse_track("Resurrections - Lena Raine", "Z", pattern="title-artist")
        self.assertEqual((p["artist"], p["title"]), ("Lena Raine", "Resurrections"))

    def test_game_name_inside_a_longer_collection_name(self):
        # Miitopia, 2026-10: the playlist was "Miitopia OST (3DS/Switch,
        # Complete)" and each video "Stage Event: Galados Isle - Miitopia".
        # The game name alone was read as the title, the track name as artist.
        album = guess_collection("Miitopia OST (3DS/Switch, Complete)", [])["name"]
        titles = ["Stage Event: Galados Isle - Miitopia", "Map: Galados Isle - Miitopia",
                  "Arrival: Peculia - Miitopia", "Ending: Divine Words- Miitopia"]
        got = guess_tracks([{"title": t} for t in titles], album)
        self.assertEqual([(p["artist"], p["title"]) for p in got], [
            ("", "Stage Event: Galados Isle"), ("", "Map: Galados Isle"),
            ("", "Arrival: Peculia"), ("", "Ending: Divine Words")])

    def test_one_title_on_every_track_is_the_collection(self):
        # Whatever the collection is called: a part shared by every track is
        # not a track name.
        titles = ["Field - Some Game", "Boss - Some Game", "Town - Some Game"]
        got = guess_tracks([{"title": t} for t in titles], "Unrelated Playlist")
        self.assertEqual([(p["artist"], p["title"]) for p in got],
                         [("", "Field"), ("", "Boss"), ("", "Town")])

    def test_dashes_in_titles_are_not_artists(self):
        # Fewer than half the titles carry a dash: they are part of the names.
        entries = [{"title": t} for t in ["Main Theme", "Main Theme - Reprise", "Battle", "Ending", "Credits"]]
        got = guess_tracks(entries, "")
        self.assertEqual(got[1]["title"], "Main Theme - Reprise")
        self.assertEqual(got[1]["artist"], "")

    def test_track_numbers_must_be_unique(self):
        entries = [{"title": "01 Intro"}, {"title": "01 Intro (Remix)"}, {"title": "Outro"}]
        self.assertEqual([p["track"] for p in guess_tracks(entries, "")], [1, 2, 3])

    def test_templates_and_names(self):
        self.assertEqual(render_template("{track:02} - {title}", {"track": 3, "title": "X"}), "03 - X")
        self.assertEqual(render_template("{track:02} - {title}", {"track": 0, "title": "X"}), "X")
        self.assertEqual(render_template("{artist} - {title}", {"artist": "", "title": "X"}), "X")
        self.assertEqual(safe_filename("AC/DC: Live?"), "AC⧸DC： Live？")
        self.assertEqual(safe_filename("CON"), "_CON")
        self.assertEqual(safe_filename("name. "), "name")


FAKE_YTDLP = r'''
import os, subprocess, sys
args = sys.argv[1:]
# FAIL_FIRST: the first try of each video is refused, as YouTube does.
calls = os.environ.get("COUNT_CALLS")
if calls:
    open(calls, "a").write("x")
if os.environ.get("BOT_BLOCK"):
    print("ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser", file=sys.stderr)
    sys.exit(1)
flag = os.environ.get("FAIL_FIRST")
if flag:
    mark = os.path.join(flag, args[-1].rsplit("/", 1)[-1] + ".tried")
    if not os.path.exists(mark):
        open(mark, "w").close()
        print("ERROR: unable to download video data: HTTP Error 403: Forbidden", file=sys.stderr)
        sys.exit(1)
out = args[args.index("-o") + 1]
ffmpeg = args[args.index("--ffmpeg-location") + 1]
fmt = args[args.index("--audio-format") + 1] if "--audio-format" in args else "best"
ext = {"best": "opus", "mp3": "mp3", "flac": "flac", "m4a": "m4a", "opus": "opus", "wav": "wav"}[fmt]
dest = out.replace("%(ext)s", ext)
codec = {"opus": "libopus", "mp3": "libmp3lame", "flac": "flac", "m4a": "aac", "wav": "pcm_s16le"}[ext]
subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                "-c:a", codec, "-metadata", "title=upload title", dest], check=True)
if "--write-thumbnail" in args:
    subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=red:s=64x36",
                    "-frames:v", "1", out.replace(".%(ext)s", ".jpg")], check=True)
print("MTP 500 1000 NA 1000 1", flush=True)
print("MTP 1000 1000 NA 1000 0", flush=True)
print("MTF " + dest, flush=True)
'''


@unittest.skipUnless(shutil.which("ffmpeg"), "needs ffmpeg")
class RunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        script = self.tmp / "fake_ytdlp.py"
        script.write_text(FAKE_YTDLP, encoding="utf-8")
        if os.name == "nt":
            self.ytdlp = self.tmp / "yt-dlp.bat"
            self.ytdlp.write_text(f'@"{sys.executable}" "{script}" %*\n', encoding="utf-8")
        else:
            self.ytdlp = self.tmp / "yt-dlp"
            self.ytdlp.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n', encoding="utf-8")
            self.ytdlp.chmod(0o755)
        self.folder = self.tmp / "out" / "Game OSTs" / "Lethal League Blaze"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def plan(self, fmt="best"):
        return {
            "ytdlp": str(self.ytdlp), "ffmpeg": shutil.which("ffmpeg"), "parallel": 2,
            "staging": str(self.tmp / "staging"),
            "items": [{
                "key": "llb", "url": "x", "mode": "audio", "audio_format": fmt, "folder": str(self.folder),
                "filename": "{track:02} - {title}", "album": "Lethal League Blaze", "album_artist": "",
                "genre": "Game Soundtrack", "year": "2018", "total": 20,
                "tracks": [
                    {"id": "GT_DW35F-vw", "url": "https://example.invalid/1", "track": 1, "artist": "AAron EVO", "title": "Beverly Chills"},
                    {"id": "iSFg_YzyESg", "url": "https://example.invalid/2", "track": 2, "artist": "B. Bravo & Lean Rock", "title": "Shred: Part 1/2"},
                ]}],
        }

    def run_plan(self, plan):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            download_job.Runner(plan).run()
        return [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]

    def tags(self, path):
        r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "json", str(path)],
                           capture_output=True)
        doc = json.loads(r.stdout)
        tags = {k.lower(): v for k, v in doc.get("format", {}).get("tags", {}).items()}
        for s in doc.get("streams", []):
            tags.update({k.lower(): v for k, v in s.get("tags", {}).items() if k.lower() not in tags})
        return tags

    def test_download_tag_file_and_skip(self):
        for fmt, ext in (("best", ".opus"), ("mp3", ".mp3")):
            with self.subTest(fmt=fmt):
                shutil.rmtree(self.tmp / "out", ignore_errors=True)
                shutil.rmtree(self.tmp / "staging", ignore_errors=True)
                events = self.run_plan(self.plan(fmt))
                done = [e for e in events if e["event"] == "track" and e["state"] == "done"]
                self.assertEqual(len(done), 2, events)
                first = self.folder / f"01 - Beverly Chills{ext}"
                second = self.folder / f"02 - Shred： Part 1⧸2{ext}"
                self.assertTrue(first.exists() and second.exists(), list(self.folder.iterdir()))
                t = self.tags(first)
                self.assertEqual((t.get("title"), t.get("artist"), t.get("album"), t.get("genre")),
                                 ("Beverly Chills", "AAron EVO", "Lethal League Blaze", "Game Soundtrack"))
                self.assertEqual(t.get("track"), "1/20")
                # The cover went in, and nothing was left behind in staging.
                r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", str(first)],
                                   capture_output=True, text=True)
                self.assertIn("video", r.stdout)
                leftovers = [p for p in (self.tmp / "staging").rglob("*") if p.is_file() and p.name != "done.json"]
                self.assertEqual(leftovers, [])

                # A second run fetches nothing.
                events = self.run_plan(self.plan(fmt))
                states = [e["state"] for e in events if e["event"] == "track"]
                self.assertEqual(states, ["skipped", "skipped"])

    def test_never_overwrites(self):
        self.folder.mkdir(parents=True)
        mine = self.folder / "01 - Beverly Chills.mp3"
        mine.write_bytes(b"the owner's own file")
        plan = self.plan("best")
        plan["items"][0]["tracks"] = plan["items"][0]["tracks"][:1]
        # The same track in another format counts as there: no second copy.
        events = self.run_plan(plan)
        self.assertEqual([e["state"] for e in events if e["event"] == "track"], ["skipped"])
        self.assertEqual(mine.read_bytes(), b"the owner's own file")
        self.assertEqual(len(list(self.folder.iterdir())), 1)
        # A clash when moving into place gets a number instead.
        runner = download_job.Runner(plan)
        src = self.tmp / "new.opus"
        src.write_bytes(b"new")
        (self.folder / "01 - Beverly Chills.opus").write_bytes(b"old")
        placed = runner.place(src, plan["items"][0], plan["items"][0]["tracks"][0], self.folder)
        self.assertEqual(placed.name, "01 - Beverly Chills (2).opus")
        self.assertEqual((self.folder / "01 - Beverly Chills.opus").read_bytes(), b"old")

    def test_403_is_tried_again(self):
        old = download_job.RETRY_WAITS
        download_job.RETRY_WAITS = (0.01, 0.01)
        os.environ["FAIL_FIRST"] = str(self.tmp)
        try:
            events = self.run_plan(self.plan())
        finally:
            download_job.RETRY_WAITS = old
            del os.environ["FAIL_FIRST"]
        states = [e["state"] for e in events if e["event"] == "track" and e["state"] in ("done", "error")]
        self.assertEqual(states, ["done", "done"], events)

    def test_bot_block_stops_the_whole_run(self):
        plan = self.plan()
        plan["parallel"] = 1
        tracks = plan["items"][0]["tracks"]
        for n in range(3, 9):  # 8 tracks
            tracks.append(dict(tracks[0], id=f"v{n}", url=f"https://example.invalid/{n}", track=n, title=f"T{n}"))
        counter = self.tmp / "calls.txt"
        os.environ["BOT_BLOCK"] = "1"
        os.environ["COUNT_CALLS"] = str(counter)
        try:
            events = self.run_plan(plan)
        finally:
            del os.environ["BOT_BLOCK"], os.environ["COUNT_CALLS"]
        self.assertEqual(len(counter.read_text()), 1, "asked again after being blocked")
        self.assertEqual([e for e in events if e["event"] == "blocked"][0]["event"], "blocked")
        self.assertFalse([e for e in events if e["event"] == "track" and e["state"] == "error"])
        self.assertTrue(download_job.BLOCKED.search("HTTP Error 429: Too Many Requests"))
        self.assertFalse(download_job.TRANSIENT.search("Sign in to confirm you're not a bot"))

    def test_permanent_errors_are_not_retried(self):
        self.assertFalse(download_job.TRANSIENT.search("Video unavailable. This video is private"))
        self.assertTrue(download_job.TRANSIENT.search("unable to download video data: HTTP Error 403: Forbidden"))

    def test_events_carry_the_track_position(self):
        # The same video twice in a playlist: the app tells them apart by uid.
        plan = self.plan()
        for i, t in enumerate(plan["items"][0]["tracks"]):
            t["uid"] = i + 10
        events = self.run_plan(plan)
        uids = {e["uid"] for e in events if e["event"] == "track"}
        self.assertEqual(uids, {10, 11})

    def test_m4a_prefers_the_sites_own_aac(self):
        runner = download_job.Runner(self.plan("m4a"))
        args = runner.ytdlp_args(self.plan("m4a")["items"][0], {"url": "u", "id": "i"}, self.tmp / "x")
        self.assertEqual(args[args.index("-f") + 1], "bestaudio[ext=m4a]/bestaudio/best")
        args = runner.ytdlp_args(self.plan("best")["items"][0], {"url": "u", "id": "i"}, self.tmp / "x")
        self.assertEqual(args[args.index("-f") + 1], "bestaudio/best")

    def test_replace_opus_with_m4a_keeps_the_tags(self):
        self.folder.mkdir(parents=True)
        old = self.folder / "01 - Beverly Chills.opus"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=d=1",
                        "-c:a", "libopus", str(old)], check=True)
        (self.folder / ".ts").mkdir()
        sidecar = {"tags": [{"title": "Lethal-League-Blaze"}]}
        (self.folder / ".ts" / (old.name + ".json")).write_text(json.dumps(sidecar))
        plan = self.plan("m4a")
        plan["items"][0]["tracks"] = plan["items"][0]["tracks"][:1]
        plan["items"][0]["tracks"][0]["replace"] = str(old)
        # A stand-in for the Recycle Bin, so the tests leave nothing in the real one.
        trashed = []
        real = download_job.send_to_trash
        download_job.send_to_trash = lambda p: (trashed.append(p.name), p.unlink(), True)[-1]
        try:
            events = self.run_plan(plan)
        finally:
            download_job.send_to_trash = real
        self.assertEqual(trashed, [old.name])
        done = [e for e in events if e["event"] == "track" and e["state"] == "done"]
        self.assertEqual(len(done), 1, events)
        new = self.folder / "01 - Beverly Chills.m4a"
        self.assertTrue(new.exists())
        self.assertFalse(old.exists())
        self.assertEqual(done[0]["replaced"], "recycled")
        self.assertEqual(json.loads((self.folder / ".ts" / (new.name + ".json")).read_text()), sidecar)
        self.assertFalse((self.folder / ".ts" / (old.name + ".json")).exists())

    def test_replace_skips_a_file_already_in_the_format(self):
        self.folder.mkdir(parents=True)
        (self.folder / "01 - Beverly Chills.opus").write_bytes(b"old")
        (self.folder / "01 - Beverly Chills.m4a").write_bytes(b"there")
        plan = self.plan("m4a")
        plan["items"][0]["tracks"] = plan["items"][0]["tracks"][:1]
        plan["items"][0]["tracks"][0]["replace"] = str(self.folder / "01 - Beverly Chills.opus")
        events = self.run_plan(plan)
        self.assertEqual([e["state"] for e in events if e["event"] == "track"], ["skipped"])

    def test_missing_ytdlp_is_an_error_not_a_crash(self):
        plan = self.plan()
        plan["ytdlp"] = str(self.tmp / "nope" / "yt-dlp.exe")
        events = self.run_plan(plan)
        errors = [e for e in events if e["event"] == "track" and e["state"] == "error"]
        self.assertEqual(len(errors), 2)
        self.assertIn("not found", errors[0]["message"])
        self.assertEqual(events[-1]["event"], "done")

    def test_cover_block(self):
        jpeg = bytes.fromhex("ffd8ffe000104a46494600010100000100010000ffc0000b080024004001011100ffd9")
        self.assertEqual(download_job._jpeg_size(jpeg), (64, 36))
        import base64
        block = base64.b64decode(download_job.flac_picture_b64(jpeg))
        self.assertEqual(int.from_bytes(block[:4], "big"), 3)  # front cover
        self.assertTrue(block.endswith(jpeg))


if __name__ == "__main__":
    unittest.main()
