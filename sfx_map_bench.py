r"""Does the effects map keep a family together?

Run this before changing the encoder, the projection or the grouping, and
after. Screenshots cannot tell you whether a map is good; this can.

    venv\Scripts\python.exe work_bench.py                  # rebuild the families
    venv\Scripts\python.exe sfx_map_bench.py               # score the current profile's cache
    venv\Scripts\python.exe sfx_map_bench.py pe-av-large   # another cache
    venv\Scripts\python.exe sfx_map_bench.py pe-av-large --quick   # skip the slow extras

The benchmark is derived from the library's own filenames — these are CamelCase
with a counter (BabyCryWhimper, Whoosh 12, Boom69), so the leading word says
what the file is and files sharing it are a family. Derived, not hand-written,
so it cannot be tuned to flatter a particular model.

The question asked is the one the map poses: for a labelled file, is its
nearest neighbour — out of *every* effect in the library, not just the
labelled ones — from its own family? "top5" is the share of the five nearest
that are, which is what hopping along neighbours feels like.

Three things are scored, all with the code the app runs (`mtag/sfxmap.py`):

  - neighbours: the embedding itself, which is what hopping and "Find more like
    this" use. Nothing is lost to a projection here.
  - the plane the map draws, by distance between dots.
  - the groups, by how pure they are (homogeneity: a group holds one family)
    and how whole (completeness: a family sits in one group).

A correction, 2026-10-01: the plane used to be scored by cosine, which on a
flat map measures the angle from the centre rather than the distance between
two dots. That read 13-16% for the UMAP map; by distance the same map scores
25-26%. Numbers before that date for the plane are not comparable.

Measured 2026-10-01 over 6567 effects, 1057 labelled, 93 families
(top1 / top5), see docs/sfx-map.md for the full table.
"""
import json, sys, warnings, time, argparse
from pathlib import Path
import numpy as np
warnings.filterwarnings("ignore")
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
from mtag.dataset import EmbeddingCache
from mtag import sfxmap

ap = argparse.ArgumentParser()
ap.add_argument("space", nargs="?", default=None, help="cache name (default: the profile's sound model)")
ap.add_argument("--quick", action="store_true", help="only the encoder, the app's plane and the app's groups")
args = ap.parse_args()
if args.space is None:
    from mtag.profiles import audio_text_space
    args.space = audio_text_space()

bench = json.loads((ROOT / "work/sfx_bench.json").read_text(encoding="utf-8"))
family_of = {str(Path(p)).lower(): fam for fam, ps in bench.items() for p in ps}
all_paths = [Path(l) for l in (ROOT / "work/sfx_all.txt").read_text(encoding="utf-8").splitlines() if l.strip()]
print(f"model cache: {args.space}")
cache = EmbeddingCache(args.space)
X, keys = [], []
for p in all_paths:
    try: v = cache.get(p)
    except (OSError, ValueError): v = None
    if v is not None and np.isfinite(v).all():
        X.append(v); keys.append(str(p).lower())
if not X:
    raise SystemExit(f"nothing cached in {cache.dir}")
X = np.asarray(X, np.float32)
lab = np.array([family_of.get(k, "") for k in keys]); idx = np.where(lab != "")[0]


def score(V, note, plane=False):
    """Top-1 and top-5 neighbour agreement for the labelled files against all.
    A plane is compared by distance, anything else by cosine."""
    V = np.asarray(V, np.float32)
    U = V if plane else sfxmap.unit(V)
    sq = (U ** 2).sum(1)
    h1 = h5 = 0.0
    for s in range(0, len(idx), 512):
        rows = idx[s:s + 512]
        S = -(sq[rows, None] - 2 * U[rows] @ U.T + sq[None, :]) if plane else U[rows] @ U.T
        S[np.arange(len(rows)), rows] = -np.inf
        o = np.argpartition(-S, 5, axis=1)[:, :5]
        o = np.take_along_axis(o, np.argsort(-np.take_along_axis(S, o, 1), 1), 1)
        h1 += (lab[o[:, 0]] == lab[rows]).sum()
        h5 += (lab[o] == lab[rows][:, None]).mean(1).sum()
    print(f"  {note:44s} top1 {h1/len(idx)*100:5.1f}%   top5 {h5/len(idx)*100:5.1f}%", flush=True)
    return h1 / len(idx)


def grouping(G, note):
    from sklearn.metrics import homogeneity_completeness_v_measure
    h, c, v = homogeneity_completeness_v_measure(lab[idx], G[idx])
    n = len(set(G.tolist()))
    print(f"  {note:44s} {n:4d} groups   pure {h*100:5.1f}%   whole {c*100:5.1f}%", flush=True)


n_lab = len(idx)
fams = {f: (lab == f).sum() for f in set(lab[idx])}
chance = sum(c * (c - 1) for c in fams.values()) / (n_lab * (len(X) - 1))
print(f"{len(X)} effects, {n_lab} labelled, {len(fams)} families, chance {chance*100:.2f}%\n")

print("neighbours (hopping, Find more like this)")
score(X, "full vector (what the app uses)")
score(sfxmap.text_half(X), "text-aligned half only")

print("\nthe plane the map draws")
t0 = time.time(); P = sfxmap.reduce_to_plane(X)
score(P, f"t-SNE perp30 (the map now, {time.time()-t0:.0f}s)", plane=True)
if not args.quick:
    import umap
    for seed in (0, 1):
        Q = umap.UMAP(n_components=2, n_neighbors=5, min_dist=0.0, metric="cosine",
                      random_state=seed).fit_transform(sfxmap.text_half(X))
        score(Q, f"UMAP n=5 seed {seed} (the map before)", plane=True)

print("\ngroups")
t0 = time.time(); G = sfxmap.group(X)
grouping(G, f"ward ~40 per group (the app, {time.time()-t0:.0f}s)")
if not args.quick:
    for size in (15, 80):
        grouping(sfxmap.group(X, size=size), f"ward ~{size} per group")
    from sklearn.cluster import HDBSCAN
    from sklearn.decomposition import PCA
    R = sfxmap.unit(PCA(50, random_state=0).fit_transform(sfxmap.unit(X)))
    for mcs in (5, 15):
        H = HDBSCAN(min_cluster_size=mcs, metric="euclidean").fit_predict(R)
        noise = (H < 0).mean()
        # Noise points each become their own group, which is what they are on a
        # map: unlabelled.
        H = np.where(H < 0, H.max() + 1 + np.arange(len(H)), H)
        grouping(H, f"HDBSCAN min {mcs} ({noise*100:.0f}% unassigned)")
