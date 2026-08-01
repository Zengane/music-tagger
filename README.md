# Music Tagger v2

Auto-tags a music library with the Mood and Sound tags from a TagSpaces tag
library, and writes them back as `.ts/*.json` sidecars.

Built for `H:\Media Browser\Mega Music Pack` — ~860 game-soundtrack tracks
tagged for video editing.

## What changed from v1

v1 asked LAION-CLAP, zero-shot, "does this sound like *goofy silly playful
cartoon comedic funny music*?" and thresholded the answer. That was never going
to work, for five separate reasons:

1. **It only heard 10 seconds.** `laion/clap-htsat-unfused`'s feature extractor
   is configured with `max_length_s=10, truncation="rand_trunc"`. v1 decoded 60
   seconds and the processor silently discarded fifty of them at random. Every
   tag came from one arbitrary 10-second slice.
2. **It ran on the CPU.** The venv had `torch==2.10.0+cpu`. `run.bat` probed
   `torch.cuda.is_available()` *before* torch was installed, so the CUDA branch
   misfired, and the later `pip install -r requirements.txt` could swap a CUDA
   build back out for a CPU one anyway.
3. **Min-max normalisation destroyed the scores.** Rescaling each category to
   [0,1] per file forces exactly one mood to 1.0 and one to 0.0 in *every*
   track, no matter what it sounds like.
4. **Thresholds were fit on positives only** — the 20th percentile of positive
   raw logits, with negative examples never consulted. Nothing stopped a
   threshold from sitting below most of the library.
5. **The vocabulary is personal.** "Build-Up", "Awkward", "Bombastic-Heavy" are
   editing cues, not audio concepts. No zero-shot model knows what they mean
   *here*.

Meanwhile the library already contained ~857 hand-tagged tracks — 2583 tag
assignments — that v1 used only to nudge thresholds.

v2 treats that as what it is: a labelled training set. It embeds each track with
a frozen music encoder and fits one logistic regression per tag on the user's
own labels. Tags are learned from examples, not from a text prompt.

## How it works

```
audio ── ffmpeg ──> 12 windows spread across the whole track
                          |
                    music encoder (frozen)
                          |
                mean + std pooled, L2 normalised
                          |
        ┌─────────────────┴──────────────────┐
   probe per tag                      zero-shot text
   (>= 12 examples)                   (rarer tags)
```

- **Whole-track windows.** Twelve windows sampled evenly from start to end, so
  intro, body and outro all count. The std half of the pooling captures how much
  a track *changes*, which is the entire signal for a tag like Build-Up.
- **One probe per tag.** Independent binary logistic regression, `C` chosen by
  cross-validation, `class_weight="balanced"` so rare tags aren't drowned.
- **Per-tag thresholds** tuned on out-of-fold predictions to maximise F-1.5.
  Recall is favoured deliberately: a missing tag is invisible in TagSpaces, a
  wrong one is one click to remove during review.
- **Zero-shot fallback** for tags with fewer than 12 examples (Wintery, Trappy,
  Romantic, Loss). Cosine similarity against the encoder's text tower, with the
  threshold set at a quantile of the library's own score distribution so the tag
  fires about 3x its current prevalence.
- **Nothing else is touched.** Game tags, star ratings and emoji tags are read
  from the existing sidecar and written straight back.

## Setup

```bash
run.bat
```

Creates a Python 3.12 venv and installs everything. Python 3.13+ is not
supported — the CUDA torch wheels lag behind.

`ffmpeg` must be on `PATH` (it already is at `C:\Program Files\ffmpeg\bin`).

## Usage

Compare encoders on your own labels:

```bash
venv\Scripts\python.exe bakeoff.py "H:\Media Browser\Mega Music Pack"
```

Train the tagger with the winning encoder:

```bash
venv\Scripts\python.exe train.py "H:\Media Browser\Mega Music Pack" --encoder muq-mulan
```

Review and write tags:

```bash
run.bat
```

Point it at a folder of new music, hit **Analyze all**, skim the suggestions,
click any tag to toggle it, then **Save all analyzed**. Every correction lands
in a sidecar, so hitting **Retrain** afterwards makes the next batch better.

## Encoders

| name | model | text tower | notes |
|---|---|---|---|
| `muq-mulan` | `OpenMuQ/MuQ-MuLan-large` | yes | music-text contrastive, 79.3 ROC-AUC zero-shot on MagnaTagATune |
| `muq` | `OpenMuQ/MuQ-large-msd-iter` | no | music SSL, probe only |
| `mert` | `m-a-p/MERT-v1-330M` | no | music SSL, probe only |
| `clap-music` | `laion/larger_clap_music_and_speech` | yes | what v1 used, wired up correctly this time |

MuQ weights are CC-BY-NC 4.0 — fine for a personal library, not for a product.

Embeddings are cached under `cache/<encoder>/` keyed by path, size and mtime, so
re-running anything is cheap and only re-encoded files get re-embedded.

## Layout

```
mtag/taxonomy.py   tag vocabulary and zero-shot prompts
mtag/sidecar.py    TagSpaces sidecar read/write
mtag/audio.py      ffmpeg decode, whole-track windowing
mtag/encoders.py   pluggable encoders
mtag/dataset.py    label collection, embedding cache
mtag/probes.py     per-tag training, CV, threshold selection
mtag/model.py      the saved tagger, zero-shot fallback heads
bakeoff.py         encoder comparison
train.py           final training
app.py             review UI
```
