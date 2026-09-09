# Expanding to a general file browser, and selling it

Written 2026-09-09. A plan, not a promise. The numbers in it that are measured
say so; the rest are estimates and should be treated as such.

The goal: the same app, but it browses images, video, 3D models and text as
well as audio, lays them all out on the map, and is sold rather than given
away. Everything stays local.

---

## 1. The licensing problem, which comes first

This is not a formality. Two of the three encoders the music tagger runs on
**cannot be used in a product that is sold.**

| Model | Licence | Sellable | Used for |
|---|---|---|---|
| `OpenMuQ/MuQ-large-msd-iter` | **CC-BY-NC-4.0** | **No** | music, 1 of 3 in the fusion |
| `OpenMuQ/MuQ-MuLan-large` | **CC-BY-NC-4.0** | **No** | music, 1 of 3 + the zero-shot text tower |
| `laion/larger_clap_music_and_speech` | Apache-2.0 | Yes | music, 1 of 3 |
| `laion/clap-htsat-unfused` | Apache-2.0 | Yes | the effects map |
| `MIT/ast-finetuned-audioset-10-10-0.4593` | BSD-3-Clause | Yes | effects tagging |

Checked against the model cards on 2026-09-09. "NC" is Non-Commercial: the
weights may not be used in anything sold, and that includes a paid app that
downloads them at run time.

The effects side is already clean. The music side is not.

### What that costs, and how to find out

The trained tagger takes a vector built from all three encoders concatenated.
Removing MuQ means retraining on what is left. The bakeoff that chose the
fusion measured it beating MuQ-MuLan alone by +0.03 macro AP — but it never
measured **CLAP alone**, which is the question that now matters.

**Every embedding needed to answer that is already cached.** No GPU time is
needed, only a retrain:

```bat
venv\Scripts\python.exe train.py "<library>" --encoder clap-music
```

Then compare macro AP and the per-tag precision against the current model.
Three outcomes:

- **Close enough** — ship CLAP-only, delete MuQ, done.
- **Noticeably worse** — look for an Apache/MIT music encoder to replace it,
  or accept the loss and say so.
- **Much worse** — the music tagging stays a free/non-commercial feature and
  the paid product leads with the other modalities.

**Do this first.** It is a day of work and it decides what the product is.

### A rule for everything added from here

Check the licence *before* wiring a model in. It is much cheaper than finding
out after the UI is built around it. Acceptable: MIT, BSD, Apache-2.0,
CC-BY-4.0. Not acceptable: anything CC-BY-**NC**, "research only",
"non-commercial", or a custom licence with a use restriction. Llama's licence
is not OSI-approved and has conditions — read it rather than assuming.

Record each decision in `docs/model-licences.md` as it is made, with the date
and the URL. The claim "we checked" needs to be evidence, not memory.

---

## 2. Why the expansion is more doable than it sounds

The app is already most of a general file browser. Every feature is built on
one shape:

1. an encoder turns a file into a vector
2. a cache keyed by path, size and modification time
3. a projection to 2D for the map
4. trained probes for tags, or text prompts for zero-shot
5. tags written as sidecars beside the file

Nothing in the map, the search, the filing, the inspector or the tagging UI is
audio-specific. **Adding a modality is adding an encoder and a file kind.**

And one image encoder covers three of the four new types:

- **Images** — encode directly.
- **Video** — sample frames with ffmpeg, which is already a dependency, encode
  each, pool them. The same trick the audio side already uses for windows.
- **3D models** — render a few turntable views offscreen, then treat them as
  images. No 3D-specific model, no new licence to check.

So the real work is *one* image encoder plus glue, not four separate systems.

---

## 3. The order to build it in

Each step ships on its own and is worth having by itself. Nothing here needs
the step after it.

### Step 0 — decide the music licence question (1 day)
As above. Everything else assumes it is settled.

### Step 1 — make the file kinds general (2–3 days)
Today a track is music or SFX. Make that an open set: Audio, Image, Video,
Model, Text. Touches the scanner, the filters, the inspector and the map's
colouring. No new models. Boring and load-bearing — do it before piling on
modalities, not after.

### Step 2 — images (3–4 days)
Candidate encoder: **SigLIP 2** (Google, Apache-2.0) or **OpenCLIP** (MIT).
Both give an image *and* a text tower, so search by description works with no
training at all — type "red car at night" and the map lights up. That is the
demo that sells this.

Thumbnails: Pillow (MIT-CMU) or ffmpeg, both already reasonable.

### Step 3 — video (2–3 days)
Sample 8–16 frames, encode with the Step 2 model, pool mean+std exactly as the
audio path does. Reuses the thumbnail and waveform-cache patterns wholesale.
Scrubbing a video in the inspector is more UI work than model work.

### Step 4 — 3D models (4–6 days, most uncertain)
Render turntable views offscreen, encode as images. `trimesh` (MIT) plus
`pyrender` (MIT) handles glTF, OBJ, STL, PLY. `.blend` and `.fbx` need Blender
in headless mode, which is GPL — fine to *call*, not to bundle inside a closed
product, so treat it as an optional external tool the way ffmpeg is treated.

Estimate this one loosely. Format coverage is where it will bite.

### Step 5 — text (4–6 days)
Two separate features, and they should not be confused:

- **Search and map placement** wants a small sentence embedder — the BGE or E5
  families, MIT-licensed, a few hundred MB. Cheap and reliable.
- **Summarising** wants a local LLM. Qwen 2.5 (Apache-2.0) is the safer
  commercial pick; Llama's licence has conditions. Several GB, slow on CPU,
  and quality varies. Ship it as an optional download, not in the base install.

---

## 4. The things that will actually hurt

Ranked by how likely they are to sink it, not by how hard they are.

1. **Install size.** The Python environment is already ~3.5 GB, plus several GB
   of models landing on C: regardless of install drive. That is already too much
   for a free tool given to friends. For something sold it is a refund. Worth
   investigating ONNX Runtime with quantised models — often a tenth of the size
   and no torch at all. This may be the single most valuable engineering work in
   the whole plan.
2. **Code signing.** The unsigned build was already quarantined by Defender as
   `Trojan:Win32/Wacatac.B!ml`. For a paid product that is fatal. A certificate
   is £100–400/year and there is no way around it.
3. **First-run experience.** Today it is: install Python, run a batch file,
   download 6 GB, hope. That cannot be what a customer meets.
4. **Support burden.** Three friends produced three different failures — no
   ffmpeg, a version mismatch, an old Python — none visible from inside the app
   until logging was added. Paying customers will produce more. The
   `diagnose.bat` and log work already done is the right instinct; keep
   extending it.
5. **Scope.** "Alternative file manager" competes with Adobe Bridge, Eagle and
   Soundly. The map is the thing none of them have. Lead with it.

---

## 5. What is already there and reusable

Worth knowing before anything is rewritten:

- the map, its camera, search highlighting, and the region labelling
- the two-phase plan/apply filing, with collisions refused and sidecars carried
- the cache keyed by path/size/mtime, and the re-keying that follows a move
- the job runner: NDJSON over a pipe, cancellable, logged
- TagSpaces sidecars, so tags travel with the files
- the trained-probe approach with per-tag measured thresholds
- `--selftest` and friends, which is how any of this stays honest

---

## 6. Rough totals

| | |
|---|---|
| Step 0, the licence decision | 1 day |
| Steps 1–3, kinds + images + video | 7–10 days |
| Step 4, 3D | 4–6 days |
| Step 5, text | 4–6 days |
| Install size and packaging | unknown, possibly the biggest item |

Three to four weeks of focused work to have images, video and 3D on the map,
assuming the music licence question resolves cleanly. The packaging work is
genuinely unestimated and could equal all of the above.

---

## 7. The first three things to do

1. Retrain on CLAP alone and compare. Decides the product.
2. Write `docs/model-licences.md` and record what is already known.
3. Prototype the image encoder on a folder of images with no UI at all —
   embed, project, measure whether the neighbours make sense, the way
   `sfx_map_bench.py` does. If the map is not good on images, none of the rest
   matters.
