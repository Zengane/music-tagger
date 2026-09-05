r"""Lay the library out on a plane by what the model hears, not by what was measured.

    venv\Scripts\python.exe map_job.py --paths-from <file> --out <json>

Why this exists. The map's Sound mode places files by eight measurements taken
off the waveform — length, loudness, brightness, bass, punch, attack, build,
sustain. For sound effects that is the right vocabulary: an effect *is* its
shape, and two files with the same shape do sound alike.

For music it says almost nothing. Every song is three minutes long, sustained,
mid-bright and moderately loud, so those eight numbers put a lullaby and a
death metal track a few pixels apart. The variation the measurements can see is
not the variation you can hear.

What the model hears is a different matter. The tagger already turns each track
into a 4096-number embedding from MuQ-MuLan, MuQ and CLAP-music, and those
vectors are trained on music: songs that sound alike land near each other in
that space. Most of the library is already embedded and sitting in `cache/`
from training, so this is usually pure arithmetic and never touches the GPU.

What actually gets mapped is one step further on. Raw embedding space is the
model's opinion of everything about a track, most of which is not what you are
looking for — production era, loudness, instrumentation, recording quality. Put
each track through the trained probes instead and you get 33 numbers: how Epic
this is, how Chill, how Goofy, in your own vocabulary. That space is smaller,
and it is made of the only distinctions you have ever said you care about.

It measures better too. Scored against labels the layout never saw — do two
tracks sharing a mood land closer than two that share none — raw fusion
embeddings give a ratio of 0.75 and probe scores give 0.66, where lower is
tighter grouping. Both beat chance; only one of them groups the way you would.

The last step is t-SNE. PCA alone gives the same clumping problem in a
different costume: it finds the widest directions and everything else piles
into the middle. t-SNE optimises for *neighbourhoods*, keeping each track next
to the tracks it is genuinely closest to, which is the question the map asks.

Effects are deliberately not mapped this way. The model is trained on music and
has nothing useful to say about a door slam; the front end places effects by
what was measured off their waveforms, which for a one-shot is the better
description anyway.

Output is NDJSON on stdout, one line at a time, like the other jobs:

    {"event": "scan",  "total": 1283, "cached": 1240, "missing": 43}
    {"event": "step",  "detail": "reducing 1240 tracks"}
    {"event": "done",  "placed": 1240, "out": "..."}

and the map itself is written to `--out` as one JSON object:

    {"version": 1, "points": {"<path>": [x, y], ...}}

with x and y in -1..1.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

import numpy as np  # noqa: E402

from mtag.dataset import EmbeddingCache  # noqa: E402
from mtag.encoders import FusionEncoder  # noqa: E402
from mtag.taxonomy import AUDIO_EXTS  # noqa: E402

DEFAULT_OUT = ROOT / "model" / "soundmap.json"


def emit(**payload) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def collect_paths(args) -> list[Path]:
    if args.paths_from:
        text = Path(args.paths_from).read_text(encoding="utf-8")
        return [Path(line) for line in text.splitlines() if line.strip()]

    root = Path(args.library)
    return [
        p for p in sorted(root.rglob("*"))
        if p.is_file() and p.suffix.lower() in AUDIO_EXTS
    ]


def load_vectors(paths: list[Path], embed_missing: bool):
    """Read each track's embedding out of the cache, or make it.

    A file that is not cached and not being embedded is simply left out. It
    keeps its place on the map's own island of unplaced files, which is honest:
    the alternative is inventing a position for it.
    """
    parts = FusionEncoder.PARTS
    caches = {name: EmbeddingCache(name) for name in parts}

    ready: list[Path] = []
    missing: list[Path] = []
    vectors: list[np.ndarray] = []

    for p in paths:
        if not p.exists():
            continue
        try:
            pieces = [caches[name].get(p) for name in parts]
        except OSError:
            pieces = [None]
        if any(v is None for v in pieces):
            missing.append(p)
            continue
        vec = np.concatenate(pieces)
        norm = np.linalg.norm(vec)
        vectors.append(vec / norm if norm > 0 else vec)
        ready.append(p)

    emit(event="scan", total=len(paths), cached=len(ready), missing=len(missing))

    if missing and embed_missing:
        enc = FusionEncoder()
        for i, p in enumerate(missing):
            try:
                vectors.append(enc.embed_file(p))
                ready.append(p)
            except Exception as exc:  # a file the decoder will not open
                emit(event="error", path=str(p), message=str(exc))
                continue
            if i % 10 == 0 or i == len(missing) - 1:
                emit(event="embed", done=i + 1, total=len(missing))

    return ready, np.asarray(vectors, dtype=np.float32)


def probe_space(X: np.ndarray):
    """Turn embeddings into one score per tag, using the trained model.

    Returns None when there is no model yet, in which case the caller maps the
    embeddings directly — worse, but it still works on a fresh install.
    """
    from mtag.model import MODEL_PATH
    import pickle

    if not Path(MODEL_PATH).exists():
        return None, []
    with open(MODEL_PATH, "rb") as f:
        model = pickle.load(f)
    probes = model["probes"] if isinstance(model, dict) else model.probes
    if not probes:
        return None, []

    tags = sorted(probes)
    scores = np.zeros((X.shape[0], len(tags)), dtype=np.float32)
    for k, tag in enumerate(tags):
        m = probes[tag]
        z = X @ np.asarray(m["coef"], dtype=np.float32) + float(m["intercept"])
        scores[:, k] = 1.0 / (1.0 + np.exp(-z))
    return scores, tags


def reduce_to_plane(X: np.ndarray, seed: int = 0) -> np.ndarray:
    """Down to 2, keeping neighbourhoods rather than spread."""
    from sklearn.decomposition import PCA
    from sklearn.manifold import TSNE

    n = X.shape[0]
    if n < 4:
        return np.zeros((n, 2), dtype=np.float32)

    # PCA first: t-SNE on thousands of raw dimensions is slow and mostly fits
    # noise. Fifty components keep the structure and cut the distance
    # computation by two orders of magnitude. On probe scores this is nearly a
    # no-op — there are only 33 to begin with — and it is kept so the fallback
    # path behaves.
    comps = int(min(50, n - 1, X.shape[1]))
    reduced = PCA(n_components=comps, random_state=seed).fit_transform(X)

    # Perplexity is roughly "how many neighbours count as the neighbourhood".
    # Too low and the map shatters into confetti; too high and it collapses
    # into one blob. Thirty is the usual choice, capped for small libraries.
    perplexity = float(max(5, min(30, (n - 1) / 3)))
    plane = TSNE(
        n_components=2,
        perplexity=perplexity,
        init="pca",
        learning_rate="auto",
        random_state=seed,
        max_iter=1000,
    ).fit_transform(reduced)

    # Into -1..1, so the front end can scale it to whatever world it draws in.
    plane = plane - plane.mean(axis=0)
    extent = float(np.abs(plane).max())
    if extent > 0:
        plane = plane / extent
    return plane.astype(np.float32)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--library", help="folder to walk for audio files")
    ap.add_argument("--paths-from", help="UTF-8 file with one audio path per line")
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument(
        "--embed-missing", action="store_true",
        help="embed files that are not in the cache yet (loads the models onto the GPU)",
    )
    args = ap.parse_args()

    if not args.library and not args.paths_from:
        emit(event="error", message="pass --library or --paths-from")
        return 2

    paths = collect_paths(args)
    if not paths:
        emit(event="error", message="no audio files found")
        return 1

    ready, X = load_vectors(paths, args.embed_missing)
    if len(ready) < 4:
        emit(event="error",
             message=f"only {len(ready)} tracks are embedded — run train.py, "
                     f"or pass --embed-missing")
        return 1

    scores, tags = probe_space(X)
    if scores is None:
        emit(event="step", detail=f"no model yet — mapping {len(ready)} tracks by embedding")
        space = X
    else:
        emit(event="step", detail=f"mapping {len(ready)} tracks across {len(tags)} tags")
        space = scores

    plane = reduce_to_plane(space)

    points = {str(p): [round(float(xy[0]), 5), round(float(xy[1]), 5)]
              for p, xy in zip(ready, plane)}

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"version": 1, "points": points}, f)

    emit(event="done", placed=len(points), out=str(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
