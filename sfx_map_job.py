"""Cached general-audio CLAP neighborhoods; no music probes or filename grouping."""
import argparse
import json
import os
from pathlib import Path
os.environ.setdefault("OMP_NUM_THREADS", "4")
import numpy as np
from mtag.dataset import EmbeddingCache

def emit(**event):
    print(json.dumps(event), flush=True)

def _encoder():
    """The profile's sound-and-text model (mtag/profiles.py): general CLAP
    on the fast profile, as before, PE-AV above it."""
    from mtag.encoders import audio_text_encoder

    return audio_text_encoder()


def load_vectors(paths):
    # Named without importing the encoders: a fully cached map never loads
    # torch at all.
    from mtag.profiles import audio_text_space

    cache = EmbeddingCache(audio_text_space())
    encoder = None
    ready, vectors = [], []
    try:
        for i, path in enumerate(paths):
            try:
                try: vector = cache.get(path)
                except (OSError, ValueError): vector = None
                if vector is None:
                    if encoder is None:
                        encoder = _encoder()
                        emit(event="step",detail=f"Loading the sound model {encoder.MODEL_ID} (first use downloads it)")
                        encoder.load()
                    vector = encoder.embed_file(path)
                    cache.put(path,vector)
                if not np.isfinite(vector).all(): raise ValueError("Invalid audio embedding")
                ready.append(path); vectors.append(vector)
            except Exception as exc:
                emit(event="step",detail=f"Skipped {path.name}: {exc}")
                if encoder is not None and not hasattr(encoder,"model"): raise
            if i % 10 == 0 or i+1 == len(paths): emit(event="embed",done=i+1,total=len(paths))
    finally:
        if encoder is not None: encoder.unload()
    return ready,np.asarray(vectors,dtype=np.float32)

# What the map is signposted with.
#
# The old labels came from the SFX tags a file carried, and most effects carry
# none — so a map of eight thousand sounds had five words on it, several of them
# wrong. CLAP is a text-audio model, so the audio can be asked what it is
# instead: every effect is scored against each phrase below, and a phrase that
# wins for enough files earns a signpost where those files sit.
#
# Plain descriptions, not tag names. This is the vocabulary of a sound library,
# written to cover the space rather than to match anything already in it.
CONCEPTS = [
 "an explosion", "a gunshot", "a heavy impact", "a punch", "breaking glass",
 "a door", "footsteps", "a whoosh", "a riser", "a downward sweep",
 "a metallic clang", "a wooden knock", "a bell", "a chime",
 "an electronic beep", "a user interface click", "a notification",
 "typing on a keyboard", "a coin", "a cash register",
 "a car engine", "a motorcycle", "a jet plane", "a helicopter", "a train",
 "tyres screeching", "a car horn",
 "rain", "thunder", "wind", "ocean waves", "a stream of water",
 "a water splash", "a water drop", "bubbles underwater",
 "fire crackling", "a flame burst",
 "birds singing", "a dog barking", "a cat", "a horse", "insects at night",
 "a baby crying", "a baby laughing", "a crowd cheering", "applause",
 "screaming", "laughter", "a cough", "breathing", "whispering",
 "singing", "a choir",
 "a drum beat", "a cymbal crash", "a bass drop", "an orchestral hit",
 "a synthesiser pad", "an ambient drone", "a low rumble", "deep sub bass",
 "machinery", "a motor whirring", "a clock ticking", "a camera shutter",
 "a zipper", "paper rustling", "cloth movement", "a switch",
 "a laser", "a science fiction weapon", "a magic spell", "a power up",
 "a sword", "a bow and arrow", "an alarm siren", "a telephone ringing",
 "a small room", "a large hall", "near silence",
 "a squeak", "a scrape", "a rattle", "a pop", "a click", "a thud", "a hiss",
]


def signpost(phrase):
    """The phrase as a label. CLAP wants a sentence; a map wants a word.

    "a baby crying" scores better as a prompt than "baby crying" does, but the
    article is dead width on a plate competing with sixty others for room.
    """
    for lead in ("a ", "an ", "the "):
        if phrase.startswith(lead):
            return phrase[len(lead):]
    return phrase


def concept_regions(paths, vectors, plane, min_files=12, limit=40):
    """Where on the map each concept lives, for signposting.

    A concept earns a signpost when it is the best match for at least
    `min_files` effects. Its position is the *median* of those files, not the
    mean: a family usually has a few members scattered across the map, and a
    mean drags the label into empty space between them.
    """
    try:
        encoder = _encoder()
        encoder.load()
        try:
            text = np.asarray(encoder.embed_text(CONCEPTS), dtype=np.float32)
        finally:
            encoder.unload()
    except Exception as exc:
        emit(event="step", detail=f"No signposts: {exc}")
        return []

    X = np.asarray(vectors, dtype=np.float32)
    half = X.shape[1] // 2
    audio = X[:, :half] if half > 0 else X
    audio = audio / (np.linalg.norm(audio, axis=1, keepdims=True) + 1e-9)
    text = text / (np.linalg.norm(text, axis=1, keepdims=True) + 1e-9)

    best = (audio @ text.T).argmax(axis=1)
    regions = []
    for i, name in enumerate(CONCEPTS):
        rows = plane[best == i]
        if len(rows) < min_files:
            continue
        centre = np.median(rows, axis=0)
        # How far that family spreads, so the app can show a loose group as a
        # wash rather than a pin.
        spread = float(np.median(np.linalg.norm(rows - centre, axis=1)))
        regions.append({"label": signpost(name),
                        "pos": [float(centre[0]), float(centre[1])],
                        "count": int(len(rows)), "spread": spread})

    # Biggest first, and only as many as a map can carry. The app drops any that
    # would still overlap, but handing it two hundred to sort through every
    # frame is work for nothing.
    regions.sort(key=lambda r: -r["count"])
    return regions[:limit]


def reduce_to_plane_sfx(vectors):
    """Flatten the effect embeddings to two dimensions for the map.

    Measured, not guessed. A benchmark of 1057 files in 93 families taken from
    the library's own filenames (BabyCry*, Whoosh*, Boom*, …) was scored on how
    often a file's nearest neighbour comes from its own family:

        the encoder's own space                32.7%   (chance 0.16%)
        t-SNE at perplexity 30, as it was       9.4%
        t-SNE at perplexity 10                 10.9%
        UMAP on the text-aligned half          16.2%

    Scored the hard way: a file's nearest neighbour may be any of the 6568, not
    just one of the labelled ones. A pilot over 1057 files read much higher —
    71.9% and 50.3% — because six times fewer distractors is a six times easier
    question. Do not quote the pilot; it flatters everything equally.

    So the projection was losing roughly two thirds of what the encoder knew,
    and now loses half. The remaining gap is the encoder's, not the layout's.
    Three details carry the gain:

    `n_neighbors=5`, which beat 3, 8 and 15 at full size — small enough that a
    family is not averaged together with whatever it sits next to, large enough
    not to shatter at six thousand points. `min_dist=0.0`
    because the map wants tight clusters, and any larger value cost 10 points
    or more. And only the first half of each vector, which is the mean block —
    the half that shares a space with CLAP's text tower. The second half is the
    standard deviation across windows, which for a half-second effect is mostly
    an artefact of padding.
    """
    import umap

    X = np.asarray(vectors, dtype=np.float32)
    half = X.shape[1] // 2
    A = X[:, :half] if half > 0 else X
    A = A / (np.linalg.norm(A, axis=1, keepdims=True) + 1e-9)

    # UMAP needs more neighbours than it has points on a tiny library.
    n_neighbors = max(2, min(5, len(A) - 1))
    plane = umap.UMAP(n_components=2, n_neighbors=n_neighbors, min_dist=0.0,
                      metric="cosine", random_state=0).fit_transform(A)
    plane = np.asarray(plane, dtype=np.float32)

    # Centred and scaled to roughly -1..1, which is what the map expects and
    # what the music layout already produces.
    plane -= plane.mean(axis=0)
    scale = np.abs(plane).max()
    if scale > 0:
        plane /= scale
    return plane


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--paths-from",required=True)
    ap.add_argument("--out",required=True)
    args=ap.parse_args()
    paths=list(dict.fromkeys(Path(p) for p in Path(args.paths_from).read_text(encoding="utf-8").splitlines() if p.strip()))
    ready,vectors=load_vectors(paths)
    if len(ready)<4: raise ValueError("At least four decodable SFX are needed; existing map kept")
    emit(event="step",detail=f"Arranging {len(ready)} effects by audio similarity")
    from threadpoolctl import threadpool_limits
    with threadpool_limits(limits=4): plane=reduce_to_plane_sfx(vectors)
    out=Path(args.out); out.parent.mkdir(parents=True,exist_ok=True)
    emit(event="step",detail="Naming the regions")
    regions=concept_regions(ready,vectors,plane)
    emit(event="step",detail=f"{len(regions)} regions named")
    from mtag.profiles import audio_text_space
    data={"version":1,"encoder":audio_text_space(),
          "points":{str(p):xy.tolist() for p,xy in zip(ready,plane)},
          "regions":regions}
    tmp=out.with_suffix(".tmp")
    tmp.write_text(json.dumps(data),encoding="utf-8"); tmp.replace(out)
    emit(event="done",placed=len(ready))
if __name__=="__main__":
    try: main()
    except Exception as exc:
        emit(event="error",message=str(exc)); raise SystemExit(1)
