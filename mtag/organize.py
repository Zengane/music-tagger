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

import json
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
    sfx_categories = {"Impacts", "Transitions", "Interface", "Footsteps", "Foley", "Ambience", "Weapons", "Vehicles", "Mechanical", "Creatures", "Voice", "Nature", "Magic", "Musical", "Liquid", "Fire", "Electricity", "Unsorted"}
    if mood == "Untagged":
        return Path(library) / "Untagged"
    if mood.startswith("SFX/") and mood[4:] in sfx_categories:
        return Path(library) / "SFX" / mood[4:]
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
    elif dst.exists() or sidecar_path(dst).exists():
        status = "collision"
    else:
        status = "ok"

    return {
        "src": str(src),
        "dst": str(dst),
        "folder": mood if mood.startswith("SFX/") else dst_dir.name,
        "mood": mood,
        "status": status,
        "creates_folder": status == "ok" and not dst_dir.exists(),
        # Carried so `apply` knows how far up it may tidy, without having to be
        # told the library separately.
        "library": str(Path(library)),
    }


def apply(entry: dict) -> dict:
    """Carry out one planned move, taking the sidecar with it."""
    if entry["status"] != "ok":
        return {**entry, "moved": False}

    src, dst = Path(entry["src"]), Path(entry["dst"])
    st = src.stat()  # read before the move; needed to re-key the embedding cache
    dst.parent.mkdir(parents=True, exist_ok=True)

    if dst.exists() or sidecar_path(dst).exists():  # lost a race with something else
        return {**entry, "moved": False, "status": "collision"}
    shutil.move(str(src), str(dst))

    # The sidecar lives in a .ts folder beside the track, so it has to follow.
    src_side, dst_side = sidecar_path(src), sidecar_path(dst)
    if src_side.exists():
        dst_side.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src_side), str(dst_side))

    rekey_caches(src, dst, st.st_size, st.st_mtime)
    lib = entry.get("library")
    pruned = _prune_empty(src.parent, Path(lib) if lib else None)
    return {**entry, "moved": True, "pruned": pruned}


SOUNDMAP = Path(__file__).resolve().parent.parent / "model" / "soundmap.json"


def rekey_soundmap(pairs, path: Path = SOUNDMAP) -> int:
    """Follow moved files through the map's own coordinates.

    The map places every track at a point and remembers it by absolute path, so
    a move loses the place. Nothing noticed: the app simply saw those tracks as
    unplaced, fell back to the layout built from measured audio, and the map
    came back looking like a different feature. Filing 1649 tracks orphaned
    1649 points at once.

    Done in one pass at the end of a run rather than per file — the map is a
    single JSON document and rewriting it per move would be a rewrite per move.

    `pairs` is an iterable of (src, dst). Returns how many points were carried
    over.
    """
    if not path.exists():
        return 0
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0

    points = doc.get("points")
    if not isinstance(points, dict):
        return 0

    moved = 0
    for src, dst in pairs:
        src, dst = str(src), str(dst)
        if src in points and src != dst:
            points[dst] = points.pop(src)
            moved += 1

    if moved:
        try:
            path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        except OSError:
            return 0
    return moved


def _prune_empty(folder: Path, library: Path | None = None) -> list[str]:
    """Drop the folder a track came out of, once nothing is left in it.

    Filing a pack empties the folders it arrived in — `Untagged/Some OST/DISC 1`
    and then `Untagged/Some OST` — and those husks used to stay behind, so the
    tree filled up with empty directories named after albums that had moved.

    Walks upward while each level is empty and stops at the library root, which
    is never removed however empty it gets. A folder still holding anything at
    all stops the walk immediately, so nothing else is touched.

    Returns the folders removed, for reporting.
    """
    removed: list[str] = []
    root = library.resolve() if library is not None else None
    here = folder

    for _ in range(8):  # deeper than any pack in practice
        try:
            here_resolved = here.resolve()
        except OSError:
            break

        # Never the library itself, and never anything outside it. Without a
        # library to compare against, do nothing at all rather than guess.
        if root is None:
            break
        if here_resolved == root or root not in here_resolved.parents:
            break

        # TagSpaces keeps its sidecars in a `.ts` beside the audio. An empty one
        # is bookkeeping, not content, so it does not count as "still in use".
        ts = here / ".ts"
        try:
            if ts.is_dir() and not any(ts.iterdir()):
                ts.rmdir()
        except OSError:
            pass

        try:
            if any(here.iterdir()):
                break
            here.rmdir()
        except OSError:
            break  # in use, or not ours to remove

        removed.append(str(here))
        here = here.parent

    return removed
