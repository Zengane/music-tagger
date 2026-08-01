"""Building the labelled dataset and the on-disk embedding cache."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import numpy as np

from .taxonomy import ALL_TAGS, AUDIO_EXTS, FOLDER_ALIASES
from . import audio as A
from .sidecar import read_taxonomy_tags

CACHE_ROOT = Path(__file__).resolve().parent.parent / "cache"


def _key(filepath: Path) -> str:
    """Cache key: path plus size and mtime, so re-encoded files re-embed."""
    st = filepath.stat()
    raw = f"{filepath.resolve()}|{st.st_size}|{int(st.st_mtime)}"
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


class EmbeddingCache:
    def __init__(self, encoder_name: str):
        self.dir = CACHE_ROOT / encoder_name
        self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, filepath: Path) -> np.ndarray | None:
        p = self.dir / f"{_key(filepath)}.npy"
        return np.load(p) if p.exists() else None

    def put(self, filepath: Path, vec: np.ndarray) -> None:
        np.save(self.dir / f"{_key(filepath)}.npy", vec.astype(np.float32))


def collect_labelled(root, exclude_dirs=("SFX",)) -> tuple[list[Path], np.ndarray]:
    """Every audio file under `root` that already carries Mood/Sound tags.

    Returns (paths, Y) where Y is a (n_files, n_tags) binary matrix aligned to
    ALL_TAGS. Folder names are *not* used as labels — they agree with the
    sidecars 822/858 of the time, and the 36 disagreements are cases where the
    user deliberately retagged a file without moving it.
    """
    root = Path(root)
    paths, rows = [], []
    for f in A.find_audio(root, AUDIO_EXTS):
        rel = f.relative_to(root)
        if rel.parts and rel.parts[0] in exclude_dirs:
            continue
        tags = read_taxonomy_tags(f)
        if not tags:
            continue
        paths.append(f)
        rows.append([1 if t in tags else 0 for t in ALL_TAGS])
    return paths, np.array(rows, dtype=np.int8)


def collect_untagged(root, exclude_dirs=("SFX",)) -> list[Path]:
    root = Path(root)
    out = []
    for f in A.find_audio(root, AUDIO_EXTS):
        rel = f.relative_to(root)
        if rel.parts and rel.parts[0] in exclude_dirs:
            continue
        if not read_taxonomy_tags(f):
            out.append(f)
    return out


def embed_all(encoder, paths: list[Path], progress=None) -> tuple[np.ndarray, list[Path]]:
    """Embed `paths`, using and filling the cache. Files that fail to decode are
    dropped and reported; returns (X, kept_paths)."""
    cache = EmbeddingCache(encoder.name)
    vecs, kept, failed = [], [], []

    for i, p in enumerate(paths):
        vec = cache.get(p)
        if vec is None:
            try:
                vec = encoder.embed_file(p)
            except Exception as e:  # decode or model failure on one file
                failed.append((p, str(e)))
                if progress:
                    progress(i + 1, len(paths), p, error=str(e))
                continue
            cache.put(p, vec)
        vecs.append(vec)
        kept.append(p)
        if progress:
            progress(i + 1, len(paths), p)

    if failed:
        print(f"\n{len(failed)} file(s) failed:", file=sys.stderr)
        for p, e in failed[:10]:
            print(f"  {p.name}: {e[:120]}", file=sys.stderr)

    return np.stack(vecs) if vecs else np.zeros((0, 0), dtype=np.float32), kept


def cli_progress(done, total, path, error=None):
    tail = f"  FAILED: {error[:60]}" if error else ""
    line = f"\r[{done}/{total}] {path.name[:60]:<60}{tail}"
    try:
        print(line, end="", flush=True)
    except UnicodeEncodeError:
        # Belt and braces: console.init() should have handled this already.
        enc = sys.stdout.encoding or "ascii"
        print(line.encode(enc, "replace").decode(enc), end="", flush=True)
    if done == total:
        print()
