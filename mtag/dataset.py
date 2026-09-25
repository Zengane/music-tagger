"""Building the labelled dataset and the on-disk embedding cache."""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

import numpy as np

from .taxonomy import ALL_TAGS, AUDIO_EXTS
from . import audio as A
from .sidecar import read_taxonomy_tags

CACHE_ROOT = Path(__file__).resolve().parent.parent / "cache"


def _key_parts(filepath: Path, size: int, mtime: float) -> str:
    raw = f"{Path(filepath).resolve()}|{size}|{int(mtime)}"
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def _key(filepath: Path) -> str:
    """Cache key: path plus size and mtime, so re-encoded files re-embed."""
    st = Path(filepath).stat()
    return _key_parts(filepath, st.st_size, st.st_mtime)


class EmbeddingCache:
    def __init__(self, encoder_name: str):
        # "fusion:clap-music+pe-av-base" is a fine encoder name and a bad
        # folder name on Windows, where ':' is not allowed.
        safe = encoder_name.replace(":", "_").replace("+", "_")
        self.dir = CACHE_ROOT / safe
        self.dir.mkdir(parents=True, exist_ok=True)

    def get(self, filepath: Path) -> np.ndarray | None:
        p = self.dir / f"{_key(filepath)}.npy"
        return np.load(p) if p.exists() else None

    def has(self, filepath: Path) -> bool:
        """Whether it is cached, without reading it.

        Planning a run asks this of every path for every part of the fusion, and
        `get` would load and throw away thousands of arrays to answer it.
        """
        return (self.dir / f"{_key(filepath)}.npy").exists()

    def put(self, filepath: Path, vec: np.ndarray) -> None:
        np.save(self.dir / f"{_key(filepath)}.npy", vec.astype(np.float32))


def rekey_caches(src: Path, dst: Path, size: int, mtime: float) -> int:
    """Follow a moved file through every encoder's cache.

    Cache keys include the path, so a file that moves into its mood folder would
    otherwise look brand new and get re-embedded. Call this after the move, with
    the size and mtime read *before* it.
    """
    if not CACHE_ROOT.exists():
        return 0
    old, new = _key_parts(src, size, mtime), _key_parts(dst, size, mtime)
    moved = 0
    for enc_dir in CACHE_ROOT.iterdir():
        if not enc_dir.is_dir():
            continue
        # Embeddings are .npy; media analysis also keeps its results (.json)
        # and thumbnails (.png) under the same key.
        for ext in (".npy", ".json", ".png"):
            old_p, new_p = enc_dir / f"{old}{ext}", enc_dir / f"{new}{ext}"
            if old_p.exists() and not new_p.exists():
                old_p.rename(new_p)
                moved += 1
    return moved


def collect_labelled(root) -> tuple[list[Path], np.ndarray]:
    """Every audio file under `root` that already carries Mood/Sound tags.

    Returns (paths, Y) where Y is a (n_files, n_tags) binary matrix aligned to
    ALL_TAGS. Folder names are *not* used as labels — they agree with the
    sidecars 822/858 of the time, and the 36 disagreements are cases where the
    user deliberately retagged a file without moving it.
    """
    root = Path(root)
    paths, rows = [], []
    for f in A.find_audio(root, AUDIO_EXTS):
        tags = read_taxonomy_tags(f)
        if not tags:
            continue
        paths.append(f)
        rows.append([1 if t in tags else 0 for t in ALL_TAGS])
    return paths, np.array(rows, dtype=np.int8)


def collect_untagged(root) -> list[Path]:
    return [f for f in A.find_audio(Path(root), AUDIO_EXTS) if not read_taxonomy_tags(f)]


def embed_all(encoder, paths: list[Path], progress=None) -> tuple[np.ndarray, list[Path]]:
    """Embed `paths`, using and filling the cache. Files that fail to decode are
    dropped and reported; returns (X, kept_paths)."""
    # A fusion encoder caches each part separately, so an outer cache would only
    # duplicate what its parts already hold.
    cache = None if getattr(encoder, "caches_internally", False) else EmbeddingCache(encoder.name)
    vecs, kept, failed = [], [], []

    for i, p in enumerate(paths):
        vec = cache.get(p) if cache else None
        if vec is None:
            try:
                vec = encoder.embed_file(p)
            except Exception as e:  # decode or model failure on one file
                failed.append((p, str(e)))
                if progress:
                    progress(i + 1, len(paths), p, error=str(e))
                continue
            if cache:
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
