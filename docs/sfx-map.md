# The effects map (Map → Sound, Effects)

Measured and built 2026-10-01. Code: `sfx_map_job.py`, `mtag/sfxmap.py`,
`ui/sfx_semantic.odin`. Bench: `sfx_map_bench.py`. Tests: `tests_sfx_map.py`
and the app's `--selftest` (`test_sfx_semantic_layout`).

## What the user sees

- Open **Map → Sound** with **Effects** in the sidebar. If the effects are not
  sorted yet, one button under the caption says **Sort N effects by sound**.
  Later it says **Map N new effects** when new files arrive, and nothing when
  the map is up to date. This is the same pattern the music map uses.
- Dots are placed by how they sound and coloured by group. Each group has a
  name on the map. The names are drawn on top of the dots.
- Click a sound: it plays, and lines go to its 8 nearest sounds. The first 5
  are numbered.
- **Right** hops to the nearest sound you have not heard on this run. **Left**
  goes back. The map pans to follow you.
- **Find more like this** (right-click, or the sort menu) puts the 20 nearest
  sounds first and orders the rest by the old 8 measurements.
- **Undo** swaps the map with the one before it. Press it again to swap back.
- Nothing writes tags or sidecars. Save still means what it did before.

## What the job does

`sfx_map_job.py --paths-from <list> --out model/sfx-soundmap.json`:

1. Embeds every effect with general CLAP (`laion/clap-htsat-unfused`, cache
   `cache/clap-sfx-v1`). It loads one model, once, for the files that are not
   cached yet.
2. Lays them out with PCA 50 + t-SNE (perplexity 30). This is the music map's
   own recipe.
3. Makes groups with Ward clustering on unit vectors, about 1 group per 40
   effects.
4. Names each group. The audio picks the best of about 100 plain phrases. A
   filename word that 60% of the group shares is used instead, but only if
   CLAP also ranks "the sound of <word>" in its top 10. This keeps "Siren" and
   "Sweeper" and drops pack words like "DSB" or "Moments". Text vectors are
   cached in `cache/clap-sfx-v1/texts.npz`.
5. Stores each effect's 20 nearest sounds by cosine on the full vector.
6. Copies the old map to `model/sfx-soundmap.prev.json` before it writes the
   new one.

If every file is cached and the map already has exactly these files, the job
stops after step 1.

## Numbers

Bench: 6,568 effects, 1,057 labelled in 93 families from the library's own
filenames, chance 0.16%. "top1" is how often the nearest sound comes from the
same family, out of all 6,568. "top5" is the share of the 5 nearest that do.

| | top1 | top5 |
|---|---|---|
| neighbours for hopping and Find more like this (no projection) | **32.7%** | 25.1% |
| new map (t-SNE), read from `model/sfx-soundmap.json` | **30.8%** | 24.8% |
| old map (UMAP n=5), same file before | 25.2% | 24.2% |

The old docs said the map scored 16.2%. That bench scored the flat map by
cosine, which on a plane measures the angle from the centre, not the distance
between two dots. Measured by distance, the old map scored 25.2%. The bench
now uses distance.

Groups (bench, general CLAP vectors):

| | pure | whole | groups |
|---|---|---|---|
| Ward, about 40 per group (used) | 83.2% | 78.3% | 164, biggest 154 |
| average linkage | 73.8% | 79.7% | 164, biggest 458 |
| HDBSCAN | 97% | 71% | leaves 2 of 3 sounds in no group |

"Pure": a group holds one family. "Whole": a family stays in one group.

Time: a full run with the vectors already cached takes 26 s. A second run
takes 3 s. Embedding new effects with CLAP takes about 0.2 s each on the
RTX 3070 Ti (200 in 34 s), so 6,568 from nothing is about 20 minutes.

Meaningless names: 200 effects copied and renamed `sfx_0001.wav`… got the
same groups (adjusted Rand 1.0), the same 5 nearest sounds (100%) and the
same map (no dot moved). Only the names can differ, because a filename word
can name a group.

## Why general CLAP and not PE-AV

Measured on the 1,057 labelled effects (nearest out of those 1,057):

| | top1 | top5 |
|---|---|---|
| general CLAP | 71.9% | 57.6% |
| PE-AV small | 67.5% | 54.9% |
| PE-AV large | 67.0% | 54.5% |
| CLAP 0.7 + PE-AV large, fused | 73.1% | 58.1% |

PE-AV is worse at "which effect sounds like this one". The fused vector gains
about 1 point, which is inside the noise for 1,057 files, and costs about
30 minutes of GPU per library. Trimming short effects instead of padding them
to 10 s did not change PE-AV's score (67.5% against 67.3%).

PE-AV stays the model for search by description and zero-shot effect tags.

**Bug found on the way:** in float16, PE-AV returned NaN for most effects.
`PeAvEncoder.load` now uses bfloat16 (same speed, no NaN); float32 is 7 times
slower. Any PE-AV vectors made before 2026-10-01 should be thrown away. None
existed on the owner's PC.

## Later

- Accept a group as a tag (one click per group). Not built: the owner asked
  to keep everything inside the Sound tab, and Save must stay meaningful.
- Probes on folder names as weak labels (`mtag/probes.py`), kept only where
  precision is measured good enough.
- Long recordings and banks: `sfx_split_job.py`, PE-A-Frame.
