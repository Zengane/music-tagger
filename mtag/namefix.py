"""Naming tracks from their tags, for rips that arrive with ids for names.

A whole soundtrack pulled off one YouTube video is split into tracks, and the
split files come out named `<video id>-92_-_Miitopia.m4a`. The real track name
is in the tags, but not where you would look: `title` holds the video's name
(the same on every track) and `artist` holds the track name. This module finds
which tag actually varies from track to track, and builds `092 - Name.m4a` from
it.

The choice is made over a whole folder, not per file, because one file alone
cannot say which of its tags is the video title. The one that differs between
files is the track name.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

from . import audio as A
from .sidecar import sidecar_path
from .taxonomy import AUDIO_EXTS

# Tags that can hold a track name, best guess first.
NAME_FIELDS = ("title", "artist", "album_artist", "composer", "performer")

_ILLEGAL = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def read_tags(path) -> dict[str, str]:
    """All tags on a file, keys lower-cased (flac/ogg use TITLE, m4a uses title)."""
    out = A._run_process(
        [A.FFPROBE, "-v", "error", "-show_entries", "format_tags", "-of", "json", str(path)],
        capture_output=True,
    )
    if out.returncode != 0:
        return {}
    try:
        tags = json.loads(out.stdout.decode("utf-8", errors="replace")).get("format", {}).get("tags", {})
    except ValueError:
        return {}
    return {k.lower(): str(v).strip() for k, v in tags.items()}


def clean(name: str) -> str:
    """A name Windows accepts: no forbidden characters, no trailing dot or space."""
    name = _ILLEGAL.sub("-", name)
    name = re.sub(r"\s+", " ", name).strip(" .")
    return name


def track_number(tags: dict[str, str]) -> tuple[int | None, int | None]:
    """(number, total) from a tag like '92/336' or '92'."""
    m = re.match(r"\s*(\d+)\s*(?:/\s*(\d+))?", tags.get("track", "") or tags.get("tracknumber", ""))
    if not m:
        return None, None
    return int(m.group(1)), int(m.group(2)) if m.group(2) else None


def pick_field(all_tags: list[dict[str, str]]) -> str | None:
    """The tag that holds the track name: the one that differs file to file.

    Needs at least 80% of files to have a distinct value, so a tag that is the
    same on every file (the video title) or only varies a little (the artist)
    is never taken for it.
    """
    if len(all_tags) < 2:
        return None
    best, best_ratio = None, 0.8
    for field in NAME_FIELDS:
        values = [t[field] for t in all_tags if t.get(field)]
        if len(values) < 0.8 * len(all_tags):
            continue
        ratio = len(set(values)) / len(all_tags)
        if ratio >= best_ratio and (best is None or ratio > best_ratio):
            best, best_ratio = field, ratio
    return best


def build_name(tags: dict[str, str], field: str, ext: str, width: int) -> str | None:
    name = clean(tags.get(field, ""))
    if not name:
        return None
    number, _ = track_number(tags)
    prefix = f"{number:0{width}d} - " if number is not None else ""
    return f"{prefix}{name}{ext}"


def plan(folder, recursive: bool = True) -> list[dict]:
    """What each folder's files would be renamed to. Touches nothing.

    status: ok, same (already named so), no-tag, collision.
    """
    root = Path(folder)
    by_dir: dict[Path, list[Path]] = {}
    for f in A.find_audio(root, AUDIO_EXTS, recursive=recursive, skip_dirs=(), skip_patterns=()):
        by_dir.setdefault(f.parent, []).append(f)

    entries = []
    for directory, files in by_dir.items():
        tags = {f: read_tags(f) for f in files}
        field = pick_field(list(tags.values()))
        totals = [track_number(t)[1] or 0 for t in tags.values()]
        numbers = [track_number(t)[0] or 0 for t in tags.values()]
        width = max(2, len(str(max(totals + numbers + [0]))))
        taken = {f.name.lower() for f in files}
        claimed: set[str] = set()
        for f in files:
            new = build_name(tags[f], field, f.suffix, width) if field else None
            status = "ok"
            if new is None:
                status = "no-tag"
            elif new == f.name:
                status = "same"
            else:
                stem, ext = Path(new).stem, Path(new).suffix
                n = 2
                while new.lower() in claimed or (new.lower() in taken and new.lower() != f.name.lower()):
                    new = f"{stem} ({n}){ext}"
                    n += 1
            if new:
                claimed.add(new.lower())
            entries.append({"src": str(f), "dst": str(f.with_name(new)) if new else None,
                            "field": field, "status": status})
    return entries


def apply(entry: dict) -> dict:
    """Rename one file, taking its sidecar and caches with it. Never overwrites."""
    if entry["status"] != "ok":
        return {**entry, "renamed": False}
    from .dataset import rekey_caches

    src, dst = Path(entry["src"]), Path(entry["dst"])
    if dst.exists() or sidecar_path(dst).exists():
        return {**entry, "renamed": False, "status": "collision"}
    st = src.stat()
    src.rename(dst)
    side = sidecar_path(src)
    if side.exists():
        shutil.move(str(side), str(sidecar_path(dst)))
    rekey_caches(src, dst, st.st_size, st.st_mtime)
    return {**entry, "renamed": True}
