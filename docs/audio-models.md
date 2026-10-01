# Better models for music and sound effects — 2026-09-25

The question: are there better models for the music and effects side, usable
in a product that is sold, that still run on ordinary hardware? And how should
a "speed or accuracy" choice work?

Short answer: **yes for effects and for search, probably for music, and the
music one has to be measured on your library before it can be trusted.**

---

## 1. What changed in the app

| | Before | Now |
|---|---|---|
| Search by describing a sound | general CLAP (2022) | **PE-AV** (Meta, Dec 2025) on Balanced and Best |
| Effect categories | AudioSet classifier (AST) + filename | the same, **plus** PE-AV asked about each category in plain words ("a rising sound effect that builds up tension") |
| Effects map | general CLAP | general CLAP on every profile: PE-AV measured worse for "sounds like this" (`docs/sfx-map.md`) |
| Music tagger | MuQ-MuLan + MuQ + CLAP-music | unchanged — **but** a PE-AV fusion can now be trained and compared (§4) |
| Speed or accuracy | one fixed set | Fast / Balanced / Best / Auto (§3) |

Nothing that already works was removed. Fast is exactly the old set of sound
models, so your existing effects map and its cache still work on Fast.

## 2. The candidates

Checked on 2026-09-25. Hugging Face itself was not reachable from the build
environment; licences come from the projects' GitHub pages and search results
quoting the model cards. Read each card once before a release.

| Model | Licence | Sellable | What it is | Verdict |
|---|---|---|---|---|
| **PE-AV** small / base / large ([facebook/pe-av-*](https://huggingface.co/facebook/pe-av-large)) | Apache-2.0 | Yes | Audio, video and text in one space. Text-to-audio retrieval score 48.1 / 50.2 / 51.6 across Meta's benchmark average (all-frames variants). Built into transformers, no remote code. | **Adopted** for Balanced (small) and Best (large). |
| PE-A-Frame small / base / large | Apache-2.0 | Yes | The same, per moment in time: *where* in a recording a sound happens. | Next step: finding one door slam inside a ten-minute ambience recording. Not wired in yet. |
| AST ([MIT/ast-finetuned-audioset](https://huggingface.co/MIT/ast-finetuned-audioset-10-10-0.4593)) | BSD-3 | Yes | AudioSet classifier, 45.9 mAP. What the effects tagger uses. | Kept. |
| CED tiny / mini / small / base ([mispeech/ced-*](https://github.com/RicherMans/CED)) | **Unclear**: the model card says Apache-2.0, the code on GitHub is GPL-3.0, and the Hugging Face model runs that code (`trust_remote_code`) | ? | AudioSet classifiers, 48.1–50.0 mAP — better than AST at a fraction of the size (5.5M–86M). | **Not used** until the licence question is answered. If it is Apache all the way down, CED-mini would replace AST on every profile: better and ten times smaller. |
| EfficientAT (mn10 / mn40) | MIT | Yes | AudioSet classifiers for CPUs, about 47–48 mAP. | Good for Fast. Needs its model code vendored (it is not in transformers). A later step. |
| Dasheng base / 0.6B / 1.2B ([mispeech/dasheng-*](https://huggingface.co/mispeech/dasheng-base)) | Apache-2.0 | Yes | General audio encoder, trained on 272k hours including music. No text tower. | A music-fusion candidate; needs the `dasheng` package. Try it if PE-AV alone does not replace MuQ. |
| GLAP ([mispeech/GLAP](https://huggingface.co/mispeech/GLAP)) | not found | ? | Multilingual audio-text model. | Licence unknown: not used. |
| CLAP (LAION, music and general) | Apache-2.0 | Yes | What the app has used since v2. | Kept on Fast and in the music fusion. |
| MuQ, MuQ-MuLan, MERT | CC-BY-NC | **No** | The music encoders the current tagger was trained on. | The reason the music tagger cannot be sold as it is. |
| Qwen2-Audio, Audio Flamingo 3 | non-commercial / research | **No** | Models that can *describe* a sound in a sentence. | Tempting for captions of effects, but not usable in a paid product. |

## 3. Speed or accuracy

`mtag/profiles.py` decides which model does each job:

| Profile | For | Images | Captions | Text | Sound search |
|---|---|---|---|---|---|
| **Fast** | any computer; the CPU is enough | SigLIP 2 base | Florence-2 base | E5 small | general CLAP |
| **Balanced** | a GPU with 4 GB, or an Apple Silicon Mac with 16 GB | SigLIP 2 base | Florence-2 base | E5 small | PE-AV small |
| **Best** | a GPU with 8 GB or more | SigLIP 2 so400m | Florence-2 large | E5 base | PE-AV large |
| **Auto** | — | picked from the GPU and memory: a 3070 Ti (8 GB) gets Best | | | |

The app has this under **Settings → Analysis models** and passes it to every
job. The future installer screen can call `python -m mtag.profiles`, which
prints the hardware it found and its recommendation as JSON.

Two honest limits:

- **Switching profile re-analyses files** the first time they are needed with
  the new models. The caches are kept per model, so switching back costs
  nothing.
- **The music tagger is not switched by a profile.** Its tags come from probes
  trained on one set of encoders; a new encoder means retraining on your own
  tags first (§4). That is also why "magic" for music cannot simply be
  downloaded: it came from training on your library, and would again.

## 4. Replacing MuQ, measured

What made the music side feel like magic is the trained probes on your own
tags, not a single model. The question is which encoders give the probes the
most to work with. On your PC, with your library:

```bat
rem 1. Score each encoder alone against your tags (embeds each one once, cached).
venv\Scripts\python.exe bakeoff.py "<library>" --encoders clap-music pe-av-small pe-av-base muq-mulan

rem 2. Train commercial fusions and compare them with the current model.
venv\Scripts\python.exe train.py "<library>" --encoder fusion:clap-music+pe-av-base
venv\Scripts\python.exe sweep.py "<library>"
```

`bakeoff.py` prints macro average precision per encoder; the current fusion
was chosen by it at +0.03 over MuQ-MuLan alone. **If `fusion:clap-music+
pe-av-base` comes within about 0.02 of the current fusion, the music tagger can
be sold** and MuQ can go. If not, Dasheng is the next thing to add to the
fusion.

## 5. Effects, measured

The effects map has a benchmark from your own filenames (`sfx_map_bench.py`).
Measured 2026-10-01: general CLAP finds a same-family nearest sound 71.9% of
the time among the 1,057 labelled effects, PE-AV small 67.5%, PE-AV large
67.0%. So the map stays on general CLAP; see `docs/sfx-map.md`.

PE-AV now loads in bfloat16. In float16 it returned NaN for most effects.

The zero-shot effect categories are scaled down (`ZS_WEIGHT` in `sfx_job.py`)
so they only apply themselves when PE-AV is very sure; the rest show as
suggestions marked "z". Once you have accepted or rejected a few hundred, their
thresholds can be set from that, the way the music tags' were.

## 6. What was tested here

No real audio model could be downloaded in the build environment. The code
paths were run with tiny random-weight PE-AV models built locally — both the
audio-only form and the audio-video form the real checkpoints use — through
the same loading code (`tests_media_models.py`): windows, pooling, text
embeddings, the model's own probabilities, fusions, and that only the trained
audio and text weights are kept. Whether PE-AV is *better* on your sounds is
what §4 and §5 measure.
