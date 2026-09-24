"""Finding files by describing them.

"explosion on black", "drake meme", "invoice from march", "tense string
build-up", "drone shot of a harbour at sunset". Each file already has one or
more vectors in the cache, made when it was analysed:

    images, video, 3D   SigLIP 2        what it looks like
    everything analysed E5              what it is described as, what it says
                                        (caption, OCR, document text, tags)
    music               CLAP (music)    what it sounds like
    sound effects       CLAP (general)  what it sounds like

A query is embedded by the text tower of each space present, compared with
every vector in that space, and the similarities are put on one scale per
space (how many standard deviations above that space's typical match) so a
strong visual match and a strong audio match can be ranked together. A file's
score is its best across spaces. Words that appear literally in a file's name,
tags, caption or OCR add a little on top: if you typed it and the file says
it, that is evidence.

The index knows nothing about models. Anything with `embed_query(texts)` that
returns unit vectors in a space's own geometry can be plugged in, which is how
the tests run without any downloads.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from . import kinds as K
from .dataset import CACHE_ROOT, _key

# How far above typical a match must be to be returned at all.
MIN_SCORE = 2.2
# Added per literal word match, scaled by the share of query words matched.
LEXICAL_BONUS = 1.5


@dataclass
class Space:
    name: str                         # cache folder
    rows: list[int] = field(default_factory=list)   # file index per row
    matrix: np.ndarray | None = None  # (rows, d), unit length
    slice_half: bool = False          # audio: the mean half of mean+std pooling


@dataclass
class FileInfo:
    path: str
    kind: str
    words: str  # lowercase haystack: name, tags, caption, OCR
    tokens: frozenset = frozenset()

    def __post_init__(self):
        self.tokens = frozenset(_words(self.words))

    def has(self, term: str) -> bool:
        """A whole word, or the start of one ("explosion" finds "explosions").
        Substrings inside words do not count: "cat" is not in "application"."""
        if term in self.tokens:
            return True
        return len(term) >= 4 and any(t.startswith(term) for t in self.tokens)


def _normalise(x: np.ndarray) -> np.ndarray:
    return x / np.maximum(np.linalg.norm(x, axis=-1, keepdims=True), 1e-8)


def _words(text: str) -> list[str]:
    return [w for w in re.findall(r"[^\W_]+", text.casefold()) if len(w) >= 2]


STOP = {"a", "an", "the", "of", "on", "in", "at", "with", "and", "or", "to", "for", "from", "by",
        "is", "it", "that", "this", "some", "le", "la", "les", "de", "des", "du", "un", "une", "et"}


class Index:
    def __init__(self, paths: list[str], spaces: dict[str, bool], media_builds: list[str]):
        """`spaces` maps cache folder name -> whether the vector is a mean+std
        pooled audio vector (only its first half is in the text space)."""
        self.files: list[FileInfo] = []
        self.spaces: dict[str, Space] = {n: Space(n, slice_half=h) for n, h in spaces.items()}
        vecs: dict[str, list[np.ndarray]] = {n: [] for n in spaces}
        for i, raw in enumerate(paths):
            p = Path(raw)
            kind = K.kind_of(p) or ""
            words = [re.sub(r"[_\-.]+", " ", p.stem)]
            try:
                key = _key(p)
            except OSError:
                self.files.append(FileInfo(raw, kind, " ".join(words).casefold()))
                continue
            words.extend(_sidecar_tags(p))
            for build in media_builds:
                doc = CACHE_ROOT / f"media-{build}" / f"{key}.json"
                if doc.exists():
                    try:
                        d = json.loads(doc.read_text(encoding="utf-8"))
                        words.extend([d.get("caption", ""), d.get("ocr", "")])
                        words.extend(t for t, v in d.get("scores", {}).items() if v[0] >= v[1] and not v[2])
                    except (OSError, json.JSONDecodeError, IndexError, TypeError):
                        pass
                    break
            self.files.append(FileInfo(raw, kind, " ".join(words).casefold()))
            for name in spaces:
                f = CACHE_ROOT / name / f"{key}.npy"
                if f.exists():
                    try:
                        v = np.load(f).astype(np.float32)
                    except (OSError, ValueError):
                        continue
                    if spaces[name]:
                        v = v[: v.shape[0] // 2]
                    if not np.isfinite(v).all():
                        continue
                    vecs[name].append(v)
                    self.spaces[name].rows.append(i)
        for name, sp in self.spaces.items():
            if vecs[name]:
                dims = {v.shape[0] for v in vecs[name]}
                if len(dims) != 1:
                    # Mixed dimensions means mixed models in one folder; keep
                    # the majority rather than fail.
                    d = max(dims, key=lambda d: sum(v.shape[0] == d for v in vecs[name]))
                    keep = [j for j, v in enumerate(vecs[name]) if v.shape[0] == d]
                    vecs[name] = [vecs[name][j] for j in keep]
                    sp.rows = [sp.rows[j] for j in keep]
                sp.matrix = _normalise(np.stack(vecs[name]))

    def counts(self) -> dict[str, int]:
        return {n: len(s.rows) for n, s in self.spaces.items() if s.rows}

    def search(self, query: str, encoders: dict, limit: int = 500) -> list[tuple[int, float]]:
        """Best matches as (file index, score), best first.

        `encoders` maps space name -> object with `embed_query([query])`.
        Spaces without an encoder are skipped.
        """
        n = len(self.files)
        best = np.full(n, -np.inf, np.float32)
        for name, sp in self.spaces.items():
            if sp.matrix is None or name not in encoders or len(sp.rows) < 2:
                continue
            q = encoders[name].embed_query([query])
            if q is None or len(q) == 0:
                continue
            q = _normalise(np.asarray(q, np.float32).reshape(1, -1))[0]
            if q.shape[0] != sp.matrix.shape[1]:
                continue
            sims = sp.matrix @ q
            # One scale for every space: how unusual this match is here.
            # Median and MAD rather than mean and SD, because the matches are
            # the outliers, and with mean/SD a few strong matches inflate the
            # spread and cap their own score — in a folder of ten files no
            # match could ever reach the bar.
            med = float(np.median(sims))
            mad = float(np.median(np.abs(sims - med))) * 1.4826
            z = (sims - med) / max(mad, 1e-3)
            rows = np.asarray(sp.rows)
            np.maximum.at(best, rows, z.astype(np.float32))

        terms = [w for w in _words(query) if w not in STOP]
        if terms:
            for i, f in enumerate(self.files):
                hit = sum(1 for w in terms if f.has(w))
                if hit:
                    bonus = LEXICAL_BONUS * hit / len(terms)
                    best[i] = (best[i] if np.isfinite(best[i]) else 0.0) + bonus
                    # Every word of the query literally there is a match on its own.
                    if hit == len(terms):
                        best[i] = max(best[i], MIN_SCORE + bonus)

        order = np.argsort(-best)
        out = []
        for i in order[:limit]:
            s = float(best[i])
            if not np.isfinite(s) or s < MIN_SCORE:
                break
            out.append((int(i), round(s, 3)))
        return out


def _sidecar_tags(p: Path) -> list[str]:
    sc = p.parent / ".ts" / (p.name + ".json")
    if not sc.exists():
        return []
    try:
        doc = json.loads(sc.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return []
    out = [t.get("title", "") for t in doc.get("tags", []) if isinstance(t, dict)]
    if doc.get("description"):
        out.append(doc["description"])
    return out
