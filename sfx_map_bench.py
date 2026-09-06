r"""Does the effects map keep a family together?

Run this before changing the encoder or the projection, and after. Screenshots
cannot tell you whether a map is good; this can.

    venv\Scripts\python.exe work_bench.py        # rebuild the families
    venv\Scripts\python.exe sfx_map_bench.py     # score them

The benchmark is derived from the library's own filenames — these are CamelCase
with a counter (BabyCryWhimper, Whoosh 12, Boom69), so the leading word says
what the file is and files sharing it are a family. Derived, not hand-written,
so it cannot be tuned to flatter a particular model.

The question asked is the one the map poses: for a labelled file, is its nearest
neighbour — out of *every* effect in the library, not just the labelled ones —
from its own family?

Measured 2026-09-07 over 6568 effects, 1057 labelled, 93 families:

    chance                                  0.16%
    encoder, full vector                   32.7%
    encoder, text-aligned half             32.6%
    t-SNE perplexity 30  (the old map)      9.4%
    t-SNE perplexity 10                    10.9%
    UMAP n_neighbors=5   (the map now)     16.2%

Two things that were tried and rejected, both by measurement:

  - `laion/clap-htsat-fused`, which handles variable-length audio and ought to
    suit half-second effects better, scored 68.2% against unfused's 71.9% on
    the smaller within-benchmark scoring. Worse, so it was not adopted.
  - Projecting through a space of 89 text prompts, the way the music map
    projects through its trained probes, scored 63.8% against 71.9% raw and
    was worse again after flattening. The text tower earns its place naming
    regions, not placing dots.

Beware the smaller number: scoring only within the 1057 labelled files reads
71.9% and 50.3% for the same two things above. Six times fewer distractors is a
six times easier question. Both numbers are honest; only one describes the map.
"""
import json, sys, warnings, time
from pathlib import Path
import numpy as np
warnings.filterwarnings("ignore")
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
from mtag.dataset import EmbeddingCache
from sklearn.manifold import TSNE
from sklearn.decomposition import PCA
import umap

bench = json.loads(Path("work/sfx_bench.json").read_text(encoding="utf-8"))
family_of = {}
for fam, ps in bench.items():
    for p in ps: family_of[str(Path(p)).lower()] = fam
all_paths = [Path(l) for l in Path("work/sfx_all.txt").read_text(encoding="utf-8").splitlines() if l.strip()]
cache = EmbeddingCache("clap-sfx-v1")
X, keys = [], []
for p in all_paths:
    v = cache.get(p)
    if v is not None and np.isfinite(v).all():
        X.append(v); keys.append(str(p).lower())
X = np.asarray(X, np.float32)
lab = np.array([family_of.get(k, "") for k in keys]); mask = lab != ""
half = X.shape[1] // 2
A = X[:, :half]; A = A / (np.linalg.norm(A, axis=1, keepdims=True) + 1e-9)
FULL = X / (np.linalg.norm(X, axis=1, keepdims=True) + 1e-9)

def agree(V, note):
    U = V / (np.linalg.norm(V, axis=1, keepdims=True) + 1e-9)
    idx = np.where(mask)[0]; hits = 0
    for s0 in range(0, len(idx), 512):
        rows = idx[s0:s0+512]
        S = U[rows] @ U.T
        for r, row in enumerate(rows): S[r, row] = -2
        hits += (lab[S.argmax(1)] == lab[rows]).sum()
    print(f"  {note:44s} {hits/len(idx)*100:5.1f}%")
    return hits/len(idx)

n_lab = mask.sum()
fams = {f: (lab == f).sum() for f in set(lab[mask])}
chance = sum(c*(c-1) for c in fams.values()) / (n_lab * (len(X)-1))
print(f"{len(X)} effects, {n_lab} labelled, {len(fams)} families, chance {chance*100:.2f}%\n")
print("what the encoder can do")
agree(FULL, "full vector (mean+std)")
agree(A,    "text-aligned half only")

print("\nflattened to the 2D the map draws")
t0=time.time(); P = TSNE(n_components=2, perplexity=30, init="pca", random_state=0).fit_transform(A)
agree(P, f"t-SNE perp30  (what it was)")
t0=time.time(); P = TSNE(n_components=2, perplexity=10, init="pca", random_state=0).fit_transform(A)
agree(P, f"t-SNE perp10")
for nb in (5, 3):
    P = umap.UMAP(n_components=2, n_neighbors=nb, min_dist=0.0, metric="cosine", random_state=0).fit_transform(A)
    agree(P, f"UMAP n={nb}  (what it is now)")
