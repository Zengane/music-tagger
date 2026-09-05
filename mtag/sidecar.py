"""Reading and writing TagSpaces `.ts/<filename>.json` sidecars."""

import json
from pathlib import Path

from .taxonomy import ALL_TAGS, GAME_ALIASES, LIBRARY_TAGS, SFX_TAGS, TAG_ALIASES

APP_NAME = "TagSpaces"
APP_VERSION = "6.5.3"


def sidecar_path(filepath) -> Path:
    p = Path(filepath)
    return p.parent / ".ts" / (p.name + ".json")


def read_sidecar(filepath) -> dict:
    """Return the parsed sidecar dict, or an empty skeleton if there is none."""
    sp = sidecar_path(filepath)
    if not sp.exists():
        return {}
    try:
        with open(sp, encoding="utf-8-sig") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def read_tags(filepath, raw: bool = False) -> list[str]:
    """All tag titles on a file, in sidecar order.

    Misspelled tags are mapped to their real names unless `raw` is set — a file
    tagged "Jazz" really is Jazzy, and reading it as an unknown tag is how 15
    already-tagged tracks ended up looking untagged.
    """
    titles = [t["title"] for t in read_sidecar(filepath).get("tags", []) if "title" in t]
    if raw:
        return titles
    return [TAG_ALIASES.get(t, GAME_ALIASES.get(t, t)) for t in titles]


def read_taxonomy_tags(filepath) -> list[str]:
    """Only the Mood/Sound tags this tool is responsible for."""
    return [t for t in read_tags(filepath) if t in ALL_TAGS]


def read_sfx_tags(filepath) -> list[str]:
    """Only the production sound-effect tags this tool is responsible for."""
    return [t for t in read_tags(filepath) if t in SFX_TAGS]


def _is_ours(title: str) -> bool:
    """Whether writing Mood/Sound tags should replace this one.

    Covers the misspellings too, so saving a file tagged "Jazz" leaves "Jazzy"
    behind rather than both.
    """
    return title in LIBRARY_TAGS or TAG_ALIASES.get(title) in LIBRARY_TAGS


def write_tags(filepath, tags: list[str], game: str | None = None) -> None:
    """Replace the Mood/Sound tags on a file, preserving everything else.

    Star ratings and emoji tags are user-curated and never touched. `game` adds a
    Game tag only when the file has none — an existing one is always kept, since
    it was chosen by hand and this one was guessed from a filename.
    """
    p = Path(filepath)
    existing = read_sidecar(p)
    kept = [t for t in existing.get("tags", []) if not _is_ours(t.get("title", ""))]
    kept_titles = {t.get("title", "") for t in kept}
    new = [{"title": tag, "type": "sidecar"} for tag in tags if tag not in kept_titles]
    if game:
        from .gametag import existing_game_tags

        if not existing_game_tags([t.get("title", "") for t in kept]):
            new.append({"title": game, "type": "sidecar"})

    ts_dir = p.parent / ".ts"
    ts_dir.mkdir(exist_ok=True)
    payload = {
        "appName": APP_NAME,
        "appVersion": APP_VERSION,
        "description": existing.get("description", ""),
        "tags": kept + new,
        "geo": existing.get("geo", {}),
    }
    with open(sidecar_path(p), "w", encoding="utf-8-sig") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
