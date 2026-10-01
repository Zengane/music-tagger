r"""Downloads playlists and videos with yt-dlp, tags them, and files them.

Started by the app's Downloads screen; reads nothing from the library and
writes only into the folders the plan names. Two jobs:

    python download_job.py probe --ytdlp <exe> --thumbs <dir> URL [URL ...]
        What each link is: playlist or video, its title, its videos, and a
        guess at the game or album name, category and track titles
        (mtag/downloads.py). Nothing is downloaded but a thumbnail.

    python download_job.py run --plan <plan.json> [--watch-stdin]
        Downloads every selected track of every item in the plan, writes the
        tags with ffmpeg, and moves each file into its item's folder under
        the name the plan's template gives it. A file already there is
        skipped, so running a playlist again fetches only what is new.
        With --watch-stdin, a line "stop" (or the app closing the pipe)
        stops every download and exits.

Both print one JSON object per line on stdout, like the other jobs.

Standard library only, so it runs before the AI environment is installed.
yt-dlp (Unlicense) is a separate program found on PATH or in bin\; ffmpeg
does the audio extraction, merging and tagging.
"""

from __future__ import annotations

import argparse
import concurrent.futures as futures
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mtag.downloads import guess_collection, guess_tracks, render_template, safe_filename  # noqa: E402

NO_WINDOW = 0x08000000 if os.name == "nt" else 0  # CREATE_NO_WINDOW
_print_lock = threading.Lock()


def emit(event: str, **fields) -> None:
    line = json.dumps({"event": event, **fields}, ensure_ascii=False)
    with _print_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def _popen(args: list[str], **kw) -> subprocess.Popen:
    return subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, creationflags=NO_WINDOW, **kw)


def resolve_exe(name: str) -> str:
    """A full path for a program given by name. yt-dlp's --ffmpeg-location
    takes a path, and a bare 'ffmpeg' there means a file in the working
    folder, which fails every conversion."""
    if os.path.isabs(name) or os.sep in name or "/" in name:
        return name
    return shutil.which(name) or name


def _last_error(stderr: str) -> str:
    """The line worth showing from a failed yt-dlp run."""
    lines = [l.strip() for l in stderr.splitlines() if l.strip()]
    for line in reversed(lines):
        if line.startswith("ERROR:"):
            return line[len("ERROR:"):].strip()
    return lines[-1] if lines else "yt-dlp stopped without saying why"


# ── probe ────────────────────────────────────────────────────────────────────

def _thumbnail_url(info: dict) -> str:
    entries = info.get("entries") or []
    first = entries[0] if entries else info
    vid = first.get("id") or ""
    if "youtube" in (info.get("extractor") or "") and vid and len(vid) == 11:
        return f"https://i.ytimg.com/vi/{vid}/mqdefault.jpg"
    for source in (info, first):
        thumbs = source.get("thumbnails") or []
        # The middle size: big enough for a card, small enough to load fast.
        jpgs = [t for t in thumbs if (t.get("url") or "").split("?")[0].endswith((".jpg", ".png"))]
        pick = jpgs or thumbs
        if pick:
            return pick[len(pick) // 2].get("url") or ""
        if source.get("thumbnail"):
            return source["thumbnail"]
    return ""


def _save_thumbnail(url: str, folder: Path, ffmpeg: str) -> str:
    if not url:
        return ""
    folder.mkdir(parents=True, exist_ok=True)
    dest = folder / (hashlib.sha1(url.encode()).hexdigest()[:16] + ".jpg")
    if dest.exists():
        return str(dest)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        data = urllib.request.urlopen(req, timeout=15).read()
    except Exception:
        return ""
    if data[:3] == b"\xff\xd8\xff" or data[:8] == b"\x89PNG\r\n\x1a\n":
        dest.write_bytes(data)
        return str(dest)
    # WebP and the rest: the window reads JPEG and PNG, so ffmpeg converts.
    raw = dest.with_suffix(".src")
    raw.write_bytes(data)
    subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-i", str(raw), "-vf", "scale=320:-2", str(dest)],
                   creationflags=NO_WINDOW, stdin=subprocess.DEVNULL, capture_output=True)
    raw.unlink(missing_ok=True)
    return str(dest) if dest.exists() else ""


def probe_one(url: str, ytdlp: str, thumbs: Path, ffmpeg: str, cookies: str) -> None:
    args = [ytdlp, "-J", "--flat-playlist", "--yes-playlist", "--no-warnings", "--color", "never"]
    if cookies:
        args += ["--cookies-from-browser", cookies]
    args.append(url)
    try:
        proc = _popen(args)
        out, err = proc.communicate(timeout=300)
    except FileNotFoundError:
        emit("probe", url=url, ok=False, message="yt-dlp was not found")
        return
    except subprocess.TimeoutExpired:
        proc.kill()
        emit("probe", url=url, ok=False, message="yt-dlp took more than 5 minutes to list this link")
        return
    if proc.returncode != 0 or not out.strip():
        emit("probe", url=url, ok=False, message=_last_error(err.decode("utf-8", "replace")))
        return
    info = json.loads(out.decode("utf-8", "replace"))
    is_list = info.get("_type") == "playlist"
    raw_entries = (info.get("entries") or []) if is_list else [info]
    entries = []
    for e in raw_entries:
        if not e:
            continue
        title = e.get("title") or e.get("id") or ""
        # Deleted and private videos stay in playlists as placeholders.
        if title in ("[Deleted video]", "[Private video]"):
            continue
        entries.append({
            "id": e.get("id") or "",
            "url": e.get("url") or e.get("webpage_url") or "",
            "title": title,
            "duration": e.get("duration") or 0,
            "uploader": e.get("uploader") or e.get("channel") or "",
        })
    title = info.get("title") or (entries[0]["title"] if entries else url)
    uploader = info.get("uploader") or info.get("channel") or ""
    guess = guess_collection(title, [e["title"] for e in entries], uploader)
    if not is_list:
        # One video: the album is the video's own game or channel, and the
        # title is what remains once the game is taken out.
        if guess["category"] != "game":
            guess["name"] = (uploader[: -len(" - Topic")] if uploader.endswith(" - Topic") else uploader) or guess["name"]
    for e, parsed in zip(entries, guess_tracks(entries, guess["name"])):
        e.update(parsed)
    year = ""
    date = info.get("upload_date") or info.get("modified_date") or ""
    if date[:4].isdigit():
        year = date[:4]
    emit("probe", url=url, ok=True, kind="playlist" if is_list else "video",
         id=info.get("id") or "", title=title, uploader=uploader,
         webpage_url=info.get("webpage_url") or url,
         thumb=_save_thumbnail(_thumbnail_url(info), thumbs, ffmpeg),
         name=guess["name"], category=guess["category"],
         album_artist=guess["album_artist"], disc=guess["disc"], year=year,
         entries=entries)


def run_probe(args: argparse.Namespace) -> int:
    thumbs = Path(args.thumbs)
    args.ytdlp, args.ffmpeg = resolve_exe(args.ytdlp), resolve_exe(args.ffmpeg)
    with futures.ThreadPoolExecutor(max_workers=3) as pool:
        for f in [pool.submit(probe_one, u, args.ytdlp, thumbs, args.ffmpeg, args.cookies) for u in args.urls]:
            try:
                f.result()
            except Exception as exc:  # one bad link must not lose the others
                emit("probe", url="", ok=False, message=f"{type(exc).__name__}: {exc}")
    emit("done")
    return 0


# ── run ──────────────────────────────────────────────────────────────────────

AUDIO_EXTS = {"mp3", "m4a", "opus", "ogg", "flac", "wav", "aac", "webm", "mka", "alac"}
VIDEO_EXTS = {"mp4", "mkv", "webm", "mov", "avi", "m4v"}


class Runner:
    def __init__(self, plan: dict):
        self.plan = plan
        self.ytdlp = resolve_exe(plan.get("ytdlp") or "yt-dlp")
        self.ffmpeg = resolve_exe(plan.get("ffmpeg") or "ffmpeg")
        self.stop = threading.Event()
        self.procs: set[subprocess.Popen] = set()
        self.lock = threading.Lock()
        self.staging = Path(plan["staging"])
        self.manifest_path = Path(plan.get("manifest") or self.staging / "done.json")
        try:
            self.manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.manifest = {}

    # stopping ---------------------------------------------------------------

    def watch_stdin(self) -> None:
        for line in sys.stdin:
            if line.strip() == "stop":
                break
        self.halt()

    def halt(self) -> None:
        self.stop.set()
        with self.lock:
            procs = list(self.procs)
        for p in procs:
            _kill_tree(p)

    # one track --------------------------------------------------------------

    def ytdlp_args(self, item: dict, track: dict, out_base: Path) -> list[str]:
        p = self.plan
        a = [self.ytdlp, "--no-playlist", "--newline", "--progress", "--color", "never",
             "--progress-template",
             "download:MTP %(progress.downloaded_bytes)s %(progress.total_bytes)s "
             "%(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s",
             "--print", "after_move:MTF %(filepath)s",
             "--ffmpeg-location", self.ffmpeg,
             "--retries", "10", "--fragment-retries", "10", "--no-mtime",
             "-o", str(out_base) + ".%(ext)s"]
        if p.get("cookies"):
            a += ["--cookies-from-browser", p["cookies"]]
        if p.get("rate"):
            a += ["--limit-rate", p["rate"]]
        if item["mode"] == "audio":
            fmt = item.get("audio_format") or "best"
            a += ["-f", "bestaudio/best", "-x", "--audio-format", fmt]
            if fmt in ("mp3", "m4a", "aac", "opus", "vorbis"):
                a += ["--audio-quality", item.get("audio_quality") or "0"]
            if item.get("embed_thumb", True) and fmt != "wav":
                # Written beside the audio, not embedded: tag() embeds it with
                # the tags, because ffmpeg cannot copy an Opus file that
                # already carries a picture.
                a += ["--write-thumbnail", "--convert-thumbnails", "jpg"]
                if item.get("square_cover", True):
                    a += ["--ppa", "ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -qmin 1 -qscale:v 2 "
                                   "-vf crop=\"'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'\""]
        else:
            h = str(item.get("video_quality") or "best")
            limit = f"[height<={h}]" if h.isdigit() else ""
            a += ["-f", f"bv*{limit}+ba/b{limit}/bv*+ba/b"]
            if item.get("video_codec") == "premiere":
                # H.264 and AAC in MP4: what Premiere and every editor open.
                a += ["-S", "vcodec:h264,acodec:aac,res,fps", "--merge-output-format", "mp4"]
            else:
                a += ["--merge-output-format", "mp4/mkv"]
            if item.get("embed_thumb", True):
                a += ["--embed-thumbnail"]
            a += ["--embed-chapters"]
            if item.get("subtitles"):
                a += ["--write-subs", "--embed-subs", "--sub-langs", item.get("sub_langs") or "en.*,ja"]
        extra = (p.get("extra") or "").strip()
        if extra:
            a += shlex.split(extra, posix=os.name != "nt")
        a.append(track["url"] or track["id"])
        return a

    def fields(self, item: dict, track: dict) -> dict:
        return {
            "track": int(track.get("track") or 0),
            "disc": int(item.get("disc") or 0),
            "title": track.get("title") or track.get("id") or "",
            "artist": track.get("artist") or item.get("album_artist") or "",
            "album": item.get("album") or "",
            "album_artist": item.get("album_artist") or "",
            "year": item.get("year") or "",
            "genre": item.get("genre") or "",
            "id": track.get("id") or "",
            "total": int(item.get("total") or 0),
        }

    def target_name(self, item: dict, track: dict) -> str:
        name = render_template(item.get("filename") or "{track:02} - {title}", self.fields(item, track))
        return safe_filename(name or track.get("id") or "track")

    def already_there(self, item: dict, track: dict, folder: Path) -> str:
        done = self.manifest.get(track.get("id") or "")
        if done and Path(done).exists() and Path(done).parent == folder:
            return done
        stem = self.target_name(item, track)
        exts = AUDIO_EXTS if item["mode"] == "audio" else VIDEO_EXTS
        for ext in exts:
            candidate = folder / f"{stem}.{ext}"
            if candidate.exists():
                return str(candidate)
        return ""

    def tag(self, src: Path, item: dict, track: dict, cover: Path | None) -> Path:
        """Writes the tags and the cover with ffmpeg, copying the sound untouched.

        The tags go through an ffmetadata file rather than -metadata
        arguments: a title may hold anything, and an Opus cover is a
        base64 tag far longer than a Windows command line allows.
        """
        f = self.fields(item, track)
        meta: dict[str, str] = {}
        if item.get("metadata", True):
            meta = {"title": f["title"], "comment": track.get("url") or "",
                    "artist": f["artist"], "album": f["album"], "date": f["year"], "genre": f["genre"]}
            if item["mode"] == "audio":
                meta.update({
                    "album_artist": f["album_artist"],
                    "track": f"{f['track']}/{f['total']}" if f["track"] and f["total"] else (str(f["track"]) if f["track"] else ""),
                    "disc": str(f["disc"]) if f["disc"] else "",
                })
        ext = src.suffix.lower()
        ogg = ext in (".opus", ".ogg")
        picture = cover is not None and cover.exists() and item["mode"] == "audio" and ext not in (".wav",)
        if picture and ogg:
            meta["METADATA_BLOCK_PICTURE"] = flac_picture_b64(cover.read_bytes())
        meta_file = src.with_name(src.stem + ".ffmeta")
        meta_file.write_text(";FFMETADATA1\n" + "".join(
            f"{_ffmeta_escape(k)}={_ffmeta_escape(v)}\n" for k, v in meta.items() if v), encoding="utf-8")
        dst = src.with_name(src.stem + ".tagged" + src.suffix)
        args = [self.ffmpeg, "-y", "-hide_banner", "-loglevel", "error", "-i", str(src)]
        if picture and not ogg:
            args += ["-i", str(cover)]
        args += ["-f", "ffmetadata", "-i", str(meta_file)]
        meta_index = 2 if (picture and not ogg) else 1
        if item["mode"] == "audio":
            args += ["-map", "0:a"]
            if picture and not ogg:
                args += ["-map", "1:v", "-disposition:v:0", "attached_pic",
                         "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
        else:
            args += ["-map", "0"]  # video, sound, subtitles, chapters, the thumbnail
        args += ["-c", "copy", "-map_metadata", str(meta_index), "-map_chapters", "0"]
        if ext == ".mp3":
            args += ["-id3v2_version", "3"]  # what Windows Explorer and Premiere read
        args.append(str(dst))
        r = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, creationflags=NO_WINDOW)
        meta_file.unlink(missing_ok=True)
        if r.returncode != 0 or not dst.exists() or dst.stat().st_size == 0:
            dst.unlink(missing_ok=True)
            raise RuntimeError("ffmpeg could not write the tags: " +
                               (r.stderr.decode("utf-8", "replace").strip().splitlines() or ["?"])[-1])
        src.unlink()
        dst.rename(src)
        return src

    def place(self, src: Path, item: dict, track: dict, folder: Path) -> Path:
        folder.mkdir(parents=True, exist_ok=True)
        stem = self.target_name(item, track)
        dest = folder / f"{stem}{src.suffix.lower()}"
        n = 2
        while dest.exists():  # never overwrite: a clash gets a number
            dest = folder / f"{stem} ({n}){src.suffix.lower()}"
            n += 1
        shutil.move(str(src), str(dest))
        return dest

    def download(self, item: dict, track: dict) -> tuple[str, str]:
        """Returns (state, detail): done/skipped/error/stopped and path or message."""
        key, tid = item["key"], track.get("id") or ""
        folder = Path(item["folder"])
        if self.stop.is_set():
            return "stopped", ""
        existing = self.already_there(item, track, folder)
        if existing:
            emit("track", key=key, id=tid, state="skipped", path=existing)
            return "skipped", existing
        work = self.staging / safe_filename(key)
        work.mkdir(parents=True, exist_ok=True)
        base = work / safe_filename(tid or hashlib.sha1(track["url"].encode()).hexdigest()[:12])
        for old in work.glob(base.name + ".*"):
            if not old.name.endswith((".part", ".ytdl")):  # a half-done download resumes
                old.unlink(missing_ok=True)
        emit("track", key=key, id=tid, state="downloading", pct=0)
        args = self.ytdlp_args(item, track, base)
        try:
            proc = _popen(args)
        except FileNotFoundError:
            return "error", "yt-dlp was not found"
        with self.lock:
            self.procs.add(proc)
        err_lines: list[str] = []
        t_err = threading.Thread(target=lambda: err_lines.extend(
            proc.stderr.read().decode("utf-8", "replace").splitlines()), daemon=True)
        t_err.start()
        final = ""
        last_emit = 0.0
        # yt-dlp downloads video and audio separately for a merge; the bar
        # shows each in turn, which is honest if a little jumpy.
        for raw in proc.stdout:
            line = raw.decode("utf-8", "replace").strip()
            if line.startswith("MTP "):
                parts = line.split()[1:]
                def num(s):
                    try:
                        return float(s)
                    except ValueError:
                        return 0.0
                got, total, est, speed, eta = (num(x) for x in (parts + ["NA"] * 5)[:5])
                total = total or est
                now = time.monotonic()
                if now - last_emit > 0.25:
                    last_emit = now
                    emit("track", key=key, id=tid, state="downloading",
                         pct=round(100 * got / total, 1) if total else 0,
                         speed=speed, eta=eta, bytes=got, total=total)
            elif line.startswith("MTF "):
                final = line[4:].strip()
        proc.wait()
        t_err.join(timeout=5)
        with self.lock:
            self.procs.discard(proc)
        if self.stop.is_set():
            return "stopped", ""
        if proc.returncode != 0 or not final or not Path(final).exists():
            return "error", _last_error("\n".join(err_lines))
        src = Path(final)
        try:
            cover = next((c for c in work.glob(base.name + ".*")
                          if c.suffix.lower() in (".jpg", ".jpeg") and c != src), None)
            if item.get("metadata", True) or cover is not None:
                emit("track", key=key, id=tid, state="tagging", pct=100)
                src = self.tag(src, item, track, cover)
            dest = self.place(src, item, track, folder)
        except (OSError, RuntimeError) as exc:
            return "error", str(exc)
        for leftover in work.glob(base.name + ".*"):  # thumbnails not embedded
            leftover.unlink(missing_ok=True)
        with self.lock:
            if tid:
                self.manifest[tid] = str(dest)
        emit("track", key=key, id=tid, state="done", path=str(dest))
        return "done", str(dest)

    # the whole plan -----------------------------------------------------------

    def run(self) -> int:
        items = self.plan.get("items") or []
        counts = {it["key"]: {"done": 0, "skipped": 0, "failed": 0, "left": len(it.get("tracks") or [])} for it in items}
        for it in items:
            emit("item", key=it["key"], state="queued", total=len(it.get("tracks") or []))
            if not it.get("tracks"):
                emit("item", key=it["key"], state="done", folder=it["folder"], done=0, skipped=0, failed=0)

        def one(it: dict, tr: dict) -> None:
            try:
                state, detail = self.download(it, tr)
            except Exception as exc:  # one track must not end the rest
                state, detail = "error", f"{type(exc).__name__}: {exc}"
            if state == "error":
                emit("track", key=it["key"], id=tr.get("id") or "", state="error", message=detail)
            with self.lock:
                c = counts[it["key"]]
                c["left"] -= 1
                if state == "done":
                    c["done"] += 1
                elif state == "skipped":
                    c["skipped"] += 1
                elif state == "error":
                    c["failed"] += 1
                finished = c["left"] == 0
                snapshot = dict(c)
            if finished and not self.stop.is_set():
                emit("item", key=it["key"], state="done", folder=it["folder"],
                     done=snapshot["done"], skipped=snapshot["skipped"], failed=snapshot["failed"])
                self.save_manifest()

        workers = max(1, min(8, int(self.plan.get("parallel") or 3)))
        with futures.ThreadPoolExecutor(max_workers=workers) as pool:
            jobs = []
            for it in items:
                emit("item", key=it["key"], state="running")
                for tr in it.get("tracks") or []:
                    jobs.append(pool.submit(one, it, tr))
            for j in jobs:
                j.result()
        self.save_manifest()
        if self.stop.is_set():
            emit("stopped")
        emit("done")
        return 0

    def save_manifest(self) -> None:
        with self.lock:
            data = json.dumps(self.manifest, ensure_ascii=False, indent=0)
        try:
            self.manifest_path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.manifest_path.with_suffix(".tmp")
            tmp.write_text(data, encoding="utf-8")
            os.replace(tmp, self.manifest_path)
        except OSError:
            pass


def _ffmeta_escape(s: str) -> str:
    s = str(s)
    for c in ("\\", "=", ";", "#", "\n"):
        s = s.replace(c, "\\" + c)
    return s


def _jpeg_size(data: bytes) -> tuple[int, int]:
    """Width and height from a JPEG's frame header, or (0, 0)."""
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2):
            h = int.from_bytes(data[i + 5:i + 7], "big")
            w = int.from_bytes(data[i + 7:i + 9], "big")
            return w, h
        i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
    return 0, 0


def flac_picture_b64(jpeg: bytes) -> str:
    """A front cover as the base64 FLAC picture block Ogg and Opus files carry."""
    import base64
    import struct
    w, h = _jpeg_size(jpeg)
    mime, desc = b"image/jpeg", b"Cover (front)"
    block = (struct.pack(">II", 3, len(mime)) + mime + struct.pack(">I", len(desc)) + desc +
             struct.pack(">IIIII", w, h, 24, 0, len(jpeg)) + jpeg)
    return base64.b64encode(block).decode("ascii")


def _kill_tree(p: subprocess.Popen) -> None:
    """yt-dlp starts ffmpeg; stopping only yt-dlp would leave ffmpeg writing."""
    if p.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True,
                       stdin=subprocess.DEVNULL, creationflags=NO_WINDOW)
    else:
        p.kill()


def run_plan(args: argparse.Namespace) -> int:
    plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))
    runner = Runner(plan)
    if args.watch_stdin:
        threading.Thread(target=runner.watch_stdin, daemon=True).start()
    return runner.run()


def main(argv: list[str] | None = None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("probe")
    p.add_argument("--ytdlp", default="yt-dlp")
    p.add_argument("--ffmpeg", default="ffmpeg")
    p.add_argument("--thumbs", required=True)
    p.add_argument("--cookies", default="")
    p.add_argument("urls", nargs="+")
    r = sub.add_parser("run")
    r.add_argument("--plan", required=True)
    r.add_argument("--watch-stdin", action="store_true")
    a = ap.parse_args(argv)
    try:
        return run_probe(a) if a.cmd == "probe" else run_plan(a)
    except Exception as exc:
        emit("error", message=f"{type(exc).__name__}: {exc}")
        emit("done")
        return 1


if __name__ == "__main__":
    sys.exit(main())
