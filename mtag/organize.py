"""Filing tracks into folders named after their primary mood.

The library is already laid out this way — `Adventure/`, `Chill/`, `Tension/`
and so on — and folder names agree with the sidecar mood tags 822 times out of
858. This keeps that arrangement true for newly tagged files.

Only Mood tags decide the folder. A track carries 1.6 moods on average, so one
of them has to be picked as primary; by default that's whichever the model
scored highest, and the UI lets you override it per file.

Nothing here overwrites: a move that would land on an existing file is refused
and reported instead.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from .dataset import rekey_caches
from .sidecar import sidecar_path
from .taxonomy import FOLDER_ALIASES, MOOD_TAGS

# Folders that hold things this tool doesn't file by mood.
RESERVED_DIRS = {"sfx", ".ts"}

# tag -> folder name already in use for it, e.g. "Build-Up" -> "Build up"
_TAG_TO_ALIAS = {tag: folder for folder, tag in FOLDER_ALIASES.items()}


def mood_folders(library) -> dict[str, Path]:
    """Existing top-level folder for each mood tag, where one exists.

    Matches the tag name, then any known alias, then case-insensitively — so
    "Build-Up" finds the "Build up" folder rather than creating a second one.
    """
    library = Path(library)
    if not library.is_dir():
        return {}
    dirs = {d.name: d for d in library.iterdir() if d.is_dir()}
    lowered = {name.lower(): d for name, d in dirs.items()}

    out = {}
    for tag in MOOD_TAGS:
        for candidate in (tag, _TAG_TO_ALIAS.get(tag)):
            if candidate and candidate in dirs:
                out[tag] = dirs[candidate]
                break
        else:
            hit = lowered.get(tag.lower())
            if hit is not None:
                out[tag] = hit
    return out


def target_folder(library, mood: str) -> Path:
    """Where a track tagged `mood` belongs. Creates nothing."""
    if mood not in MOOD_TAGS:
        raise ValueError(f"{mood!r} is not a Mood tag")
    return mood_folders(library).get(mood, Path(library) / mood)


def primary_mood(selected: list[str], scores: dict | None = None) -> str | None:
    """The mood a file should be filed under: the highest-scoring one selected."""
    moods = [t for t in selected if t in MOOD_TAGS]
    if not moods:
        return None
    if not scores:
        return moods[0]
    return max(moods, key=lambda t: scores.get(t, {}).get("score", 0.0))


def plan(filepath, library, mood: str) -> dict:
    """What moving `filepath` under `mood` would do. Touches nothing.

    status is one of: ok, already-there, collision, missing.
    """
    src = Path(filepath)
    dst_dir = target_folder(library, mood)
    dst = dst_dir / src.name

    if not src.is_file():
        status = "missing"
    elif src.parent.resolve() == dst_dir.resolve():
        status = "already-there"
    elif dst.exists():
        status = "collision"
    else:
        status = "ok"

    return {
        "src": str(src),
        "dst": str(dst),
        "folder": dst_dir.name,
        "mood": mood,
        "status": status,
        "creates_folder": status == "ok" and not dst_dir.exists(),
    }


def apply(entry: dict) -> dict:
    """Carry out one planned move, taking the sidecar with it."""
    if entry["status"] != "ok":
        return {**entry, "moved": False}

    src, dst = Path(entry["src"]), Path(entry["dst"])
    st = src.stat()  # read before the move; needed to re-key the embedding cache
    dst.parent.mkdir(parents=True, exist_ok=True)

    if dst.exists():  # lost a race with something else
        return {**entry, "moved": False, "status": "collision"}
    shutil.move(str(src), str(dst))

    # The sidecar lives in a .ts folder beside the track, so it has to follow.
    src_side, dst_side = sidecar_path(src), sidecar_path(dst)
    if src_side.exists():
        dst_side.parent.mkdir(parents=True, exist_ok=True)
        if dst_side.exists():
            dst_side.unlink()
        shutil.move(str(src_side), str(dst_side))

    rekey_caches(src, dst, st.st_size, st.st_mtime)
    _prune_empty(src.parent)
    return {**entry, "moved": True}


def _prune_empty(folder: Path) -> None:
    """Drop a leftover empty .ts directory.

    The folder that held the track is left alone even if it's now empty — an
    empty "Melancholic" is still a folder the user made, and deleting it is not
    this tool's call.
    """
    ts = folder / ".ts"
    try:
        if ts.is_dir() and not any(ts.iterdir()):
            ts.rmdir()
    except OSError:
        pass  # in use, or not ours to remove
