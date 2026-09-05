"""Small, local boolean search over audio names and TagSpaces sidecar tags."""

from __future__ import annotations

import shlex
from difflib import SequenceMatcher
from pathlib import Path

from .sidecar import read_tags
from .taxonomy import GAME_TAGS


def parse(query: str) -> list[tuple[str, str]]:
    """Parse AND terms such as ``tag:Epic tag:Orchestral game:Celeste``.

    Quoted values are accepted. A bare term searches the filename, relative
    path and all sidecar tags. Every term must match, which makes combining
    tags predictable for an editor's library search.
    """
    try:
        tokens = shlex.split(query or "")
    except ValueError:
        tokens = (query or "").split()
    out = []
    for token in tokens:
        prefix = token[:1]
        if prefix in {"+", "-", "|"} and len(token) > 1:
            out.append(({"+": "must", "-": "not", "|": "or"}[prefix],
                        token[1:].casefold()))
            continue
        if ":" in token:
            key, value = token.split(":", 1)
            if key.lower() in {"tag", "game", "name"} and value:
                out.append((key.lower(), value.casefold()))
                continue
        out.append(("text", token.casefold()))
    return out


def matches(path: Path, query: str, tags: list[str] | None = None) -> bool:
    terms = parse(query)
    if not terms:
        return True
    tags = tags if tags is not None else read_tags(path)
    tag_text = [t.casefold() for t in tags]
    name_text = path.name.casefold()
    path_text = str(path).casefold()
    def fuzzy(value: str, candidates: list[str]) -> bool:
        if value in candidates or any(value in c for c in candidates):
            return True
        if len(value) < 4:
            return False
        return any(
            max((SequenceMatcher(None, value, c[i:i + len(value) + 2]).ratio()
                 for i in range(max(1, len(c) - len(value) + 1))), default=0) >= 0.72
            for c in candidates
        )

    or_terms = [value for kind, value in terms if kind == "or"]
    if or_terms and not any(fuzzy(value, tag_text) for value in or_terms):
        return False
    for kind, value in terms:
        if kind in {"or", "not", "must", "tag"}:
            if kind == "not":
                if fuzzy(value, tag_text):
                    return False
            elif kind == "or":
                continue
            elif not fuzzy(value, tag_text):
                return False
        elif kind == "game":
            if not any(
                (value == tag.casefold() or value in tag.casefold())
                and tag in GAME_TAGS
                for tag in tags
            ):
                return False
        elif kind == "name":
            if value not in name_text:
                return False
        elif not fuzzy(value, [name_text, path_text, *tag_text]):
            return False
    return True
