"""Reading the game name out of a filename or the folder holding it.

Game tags aren't predicted from audio — two Mario Galaxy tracks sound nothing
alike, and the name is usually written on the file already. When you drop a new
folder in, "Xenoblade Chronicles OST/" or "... - Super Mario Odyssey OST.mp3"
carries the answer.

Where the name isn't written down — "05 Sneakman", "A Few Screws Loose",
"2 Shop Theme" — this returns nothing rather than guessing.
"""

from __future__ import annotations

import re
import unicodedata
from pathlib import Path

from .taxonomy import (CONTAINER_DIRS, FOLDER_ALIASES, GAME_ALIASES, GAME_PHRASES,
                       GAME_TAGS, MOOD_TAGS)

# Longest phrase first, so "super mario galaxy" is tested before "mario galaxy",
# and "shin megami tensei iv" before "shin megami tensei".
_PHRASES: list[tuple[str, str]] = sorted(
    ((p, tag) for tag, ps in GAME_PHRASES.items() for p in ps),
    key=lambda x: -len(x[0]),
)


def _norm_plain(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower()
    text = re.sub(r"[^\w\s&']", " ", text, flags=re.UNICODE)
    return re.sub(r"\s+", " ", text).strip()


# Folders named after a mood say where a track is filed, not where it came from.
_MOOD_FOLDER_NAMES = {_norm_plain(t) for t in MOOD_TAGS} | {
    _norm_plain(f) for f in FOLDER_ALIASES
}


def normalise(text: str) -> str:
    """Lowercase, strip accents and punctuation, collapse whitespace.

    Ripped filenames substitute unicode look-alikes for characters Windows
    forbids — ｜ for |, ⧸ for /, ＂ for " — so those have to fall out too.
    """
    return _norm_plain(text)


def canonical(tag: str) -> str:
    """Map a superseded game tag onto the name the tag library uses now."""
    return GAME_ALIASES.get(tag, tag)


def from_text(text: str) -> str | None:
    hay = f" {normalise(text)} "
    for phrase, tag in _PHRASES:
        if f" {normalise(phrase)} " in hay:
            return tag
    return None


_NOISE_WORDS = {
    "ost", "soundtrack", "music", "original", "full", "complete", "extended",
    "best", "tracks", "songs", "album", "vol", "gamerip", "download",
}

# "DISC 1", "CD2" — a subfolder of an album, not the name of anything.
_DISC = re.compile(r"^(disc|disk|cd)\s*\d*$", re.IGNORECASE)

_BRACKETED = re.compile(r"[(\[{][^)\]}]*[)\]}]")


def tag_from_folder(name: str) -> str | None:
    """Turn a folder name into a tag styled like the existing Game tags.

        "Wario World OST"                 -> "Wario-World"
        "Best Mario Kart Tracks"          -> "Mario-Kart"
        "Terraria Soundtrack (1 4 4)"     -> "Terraria"
        "VA-11 Hall-A"                    -> "VA-11-Hall-A"

    Capitalisation the user typed is kept, since "TF2" and "VA-11" shouldn't be
    reflowed. Returns None when nothing but boilerplate is left.
    """
    tokens = []
    for tok in _BRACKETED.sub(" ", name).split():
        if re.sub(r"\W", "", tok).lower() in _NOISE_WORDS:
            continue
        tokens.append(tok.capitalize() if tok.islower() else tok)

    if tokens and tokens[0].lower() == "the":
        tokens = tokens[1:]  # a leading "The" adds nothing; internal ones read fine
    if not tokens:
        return None
    return "-".join(tokens).strip("-")[:60].strip("-") or None


def _folder_chain(p: Path, root: Path | None):
    """Folders between the file and the library root, nearest first.

    Mood folders, staging folders and per-disc subfolders are stepped over, so a
    track in "Bayonetta/DISC 3/" resolves to Bayonetta.
    """
    for parent in p.parents:
        if root is not None and parent == root:
            return
        n = normalise(parent.name)
        if n not in _MOOD_FOLDER_NAMES and n not in CONTAINER_DIRS and not _DISC.match(n):
            yield parent
        if root is None:
            return  # with no root to stop at, don't wander up the whole drive


def detect_detail(filepath, library_root=None) -> tuple[str | None, str | None, bool]:
    """Best guess at the game, where it came from, and whether it's a new tag.

    The filename is checked first, then each folder between the file and the
    library root — "01 Main Theme" inside "A Hat in Time OST/" still resolves.
    Mood folders and staging folders like "Untagged" are stepped over.

    When nothing in the known list matches, the containing folder is offered as
    a *new* tag: most of a fresh drop is games the tag library hasn't heard of
    yet, and "Bayonetta/" names itself. Those come back with is_new=True and are
    never written without being confirmed.
    """
    p = Path(filepath).resolve()
    root = Path(library_root).resolve() if library_root else None

    hit = from_text(p.stem)
    if hit:
        return hit, "filename", False

    chain = list(_folder_chain(p, root))
    for parent in chain:
        hit = from_text(parent.name)
        if hit:
            return hit, f"folder {parent.name!r}", False

    for parent in chain:
        candidate = tag_from_folder(parent.name)
        if candidate:
            return candidate, f"folder {parent.name!r}", True
    return None, None, False


def detect(filepath, library_root=None) -> str | None:
    """Known game tags only. Folder-derived new names are excluded."""
    tag, _, is_new = detect_detail(filepath, library_root)
    return None if is_new else tag


def existing_game_tags(tags: list[str]) -> list[str]:
    """The game tags already on a file, normalised to current names."""
    known = set(GAME_TAGS) | set(GAME_ALIASES)
    return [canonical(t) for t in tags if t in known]
