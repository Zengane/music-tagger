r"""Sort the sound effects by how they sound: one job, started from the map.

    venv\Scripts\python.exe sfx_map_job.py --paths-from <file> --out <json>

What it does, in order, and what each step costs on a second run:

  1. Embed every effect with the profile's sound model (PE-AV on Balanced and
     Best, general CLAP on Fast). One model, loaded once, over every file that
     is not cached yet. Cached per file (`mtag/dataset.py`), so a rerun only
     embeds what is new.
  2. Lay them out on a plane (PCA + t-SNE, the music map's own recipe).
  3. Group them (agglomerative clustering on cosine distance) and name each
     group from the audio, or from a filename word its files agree on.
  4. Find each effect's 20 nearest neighbours, for hopping on the map and for
     "Find more like this".

Nothing here reads or writes tags. The previous map is kept next to the new
one as `<out>.prev.json`, and the app's Undo swaps the two.

If every path is cached and the map on disk already holds exactly these files
from this model, the job stops after step 1: nothing to do.

Output is NDJSON on stdout, as the other jobs:

    {"event": "scan",  "total": 6568, "cached": 6500, "missing": 68}
    {"event": "embed", "part": "pe-av-large", "done": 10, "total": 68}
    {"event": "step",  "detail": "..."}
    {"event": "done",  "placed": 6568}

and the map is one JSON object:

    {"version": 2, "encoder": "pe-av-large",
     "points":  {"<path>": [x, y], ...},          x, y in -1..1
     "regions": [{"label", "group", "pos", "count", "spread"}, ...],
     "paths":   ["<path>", ...],                   the order of the two below
     "group":   [g, ...],                          group of each path
     "nn":      [[i, ...], ...]}                   20 nearest, closest first
"""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
os.environ.setdefault("OMP_NUM_THREADS", "4")
import numpy as np
from mtag.dataset import EmbeddingCache
from mtag import sfxmap

NEIGHBOURS = 20


def emit(**event):
    print(json.dumps(event), flush=True)


def _encoder():
    """The profile's sound-and-text model (mtag/profiles.py)."""
    from mtag.encoders import audio_text_encoder

    return audio_text_encoder()


def _space():
    # Named without importing the encoders: a fully cached map never loads
    # torch at all.
    from mtag.profiles import audio_text_space

    return audio_text_space()


class Model:
    """The encoder, loaded on first use and only once."""

    def __init__(self):
        self.encoder = None

    def get(self):
        if self.encoder is None:
            self.encoder = _encoder()
            emit(event="step", detail=f"Loading the sound model {self.encoder.MODEL_ID} (first use downloads it)")
            self.encoder.load()
        return self.encoder

    def close(self):
        if self.encoder is not None:
            self.encoder.unload()
            self.encoder = None


def load_vectors(paths, model=None):
    """Every path's vector, from the cache or embedded now. Files that will
    not decode are left off the map and reported."""
    cache = EmbeddingCache(_space())
    own = model is None
    model = model or Model()
    ready, vectors, missing = [], [], []
    for path in paths:
        try:
            vector = cache.get(path)
        except (OSError, ValueError):
            vector = None
        if vector is None:
            missing.append(path)
        elif np.isfinite(vector).all():
            ready.append(path); vectors.append(vector)
    emit(event="scan", total=len(paths), cached=len(ready), missing=len(missing))
    try:
        for i, path in enumerate(missing):
            try:
                encoder = model.get()
                vector = encoder.embed_file(path)
                if not np.isfinite(vector).all():
                    raise ValueError("Invalid audio embedding")
                cache.put(path, vector)
                ready.append(path); vectors.append(vector)
            except Exception as exc:
                emit(event="error", path=str(path), message=f"Skipped {path.name}: {exc}")
                if model.encoder is not None and not hasattr(model.encoder, "model"):
                    raise
            if i % 10 == 0 or i + 1 == len(missing):
                emit(event="embed", part=_space(), done=i + 1, total=len(missing))
    finally:
        if own:
            model.close()
    return ready, np.asarray(vectors, dtype=np.float32)


def concept_text(model):
    """The text vectors for the naming phrases, cached next to the audio
    vectors so a rerun does not load the model just to read them again."""
    cache = EmbeddingCache(_space())
    digest = hashlib.sha1("\n".join(sfxmap.CONCEPTS).encode("utf-8")).hexdigest()[:12]
    path = cache.dir / f"concepts-{digest}.npy"
    if path.exists():
        try:
            return np.load(path)
        except (OSError, ValueError):
            pass
    text = model.get().embed_text(sfxmap.CONCEPTS)
    if text is None:
        return None
    text = np.asarray(text, dtype=np.float32)
    np.save(path, text)
    return text


def up_to_date(out: Path, ready) -> bool:
    """The map on disk already holds exactly these files from this model."""
    try:
        doc = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return (doc.get("version") == 2 and doc.get("encoder") == _space()
            and set(doc.get("paths", [])) == {str(p) for p in ready})


def build(ready, vectors, text):
    """Everything the map needs, from vectors alone."""
    from threadpoolctl import threadpool_limits

    emit(event="step", detail=f"Arranging {len(ready)} effects by how they sound")
    with threadpool_limits(limits=4):
        plane = sfxmap.reduce_to_plane(vectors)
    emit(event="step", detail="Grouping sounds that are alike")
    groups = sfxmap.group(vectors)
    emit(event="step", detail="Naming the groups")
    names = sfxmap.name_groups(ready, groups, sfxmap.text_half(vectors), text)
    regions = sfxmap.regions(plane, groups, names)
    emit(event="step", detail="Finding each sound's nearest neighbours")
    nn = sfxmap.nearest(vectors, NEIGHBOURS)
    return {
        "version": 2,
        "encoder": _space(),
        "points": {str(p): [round(float(x), 5), round(float(y), 5)] for p, (x, y) in zip(ready, plane)},
        "regions": regions,
        "paths": [str(p) for p in ready],
        "group": groups.tolist(),
        "nn": nn.tolist(),
    }


def write(out: Path, data: dict):
    """Write the map, keeping the one it replaces as `<out>.prev.json`."""
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, separators=(",", ":")), encoding="utf-8")
    if out.exists():
        shutil.copy2(out, prev_path(out))
    tmp.replace(out)


def prev_path(out: Path) -> Path:
    return out.with_name(out.stem + ".prev.json")


def main():
    # UTF-8 output, and background priority when the app started this job.
    from mtag import console
    console.init()
    ap = argparse.ArgumentParser()
    ap.add_argument("--paths-from", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    paths = list(dict.fromkeys(Path(p) for p in Path(args.paths_from).read_text(encoding="utf-8").splitlines() if p.strip()))
    out = Path(args.out)
    model = Model()
    try:
        ready, vectors = load_vectors(paths, model)
        if len(ready) < 4:
            raise ValueError("At least four decodable effects are needed; the existing map is kept")
        if up_to_date(out, ready):
            emit(event="step", detail="The effects map is already up to date")
            emit(event="done", placed=len(ready))
            return
        try:
            text = concept_text(model)
        except Exception as exc:
            emit(event="step", detail=f"No names from the sound model: {exc}")
            text = None
    finally:
        model.close()
    data = build(ready, vectors, text)
    write(out, data)
    emit(event="done", placed=len(ready))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        emit(event="error", message=str(exc))
        raise SystemExit(1)
