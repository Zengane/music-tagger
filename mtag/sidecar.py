"""Reading and writing TagSpaces `.ts/<filename>.json` sidecars."""

import json
from pathlib import Path

from .taxonomy import ALL_TAGS

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


def read_tags(filepath) -> list[str]:
    """All tag titles on a file, in sidecar order."""
    return [t["title"] for t in read_sidecar(filepath).get("tags", []) if "title" in t]


def read_taxonomy_tags(filepath) -> list[str]:
    """Only the Mood/Sound tags this tool is responsible for."""
    return [t for t in read_tags(filepath) if t in ALL_TAGS]


def write_tags(filepath, tags: list[str]) -> None:
    """Replace the Mood/Sound tags on a file, preserving everything else.

    Game tags, star ratings and emoji tags are user-curated and never touched.
    """
    p = Path(filepath)
    existing = read_sidecar(p)
    kept = [t for t in existing.get("tags", []) if t.get("title") not in ALL_TAGS]
    new = [{"title": tag, "type": "sidecar"} for tag in tags]

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
