# Expanding to a general file browser, and selling it

Written 2026-09-09, revised the same day after a conversation that changed the
order. A plan, not a promise. The numbers in it that are measured say so; the
rest are estimates and should be treated as such.

**The goal:** one tool for everyone who works with files that are hard to name
— 3D artists, designers, editors, and music people to the extent the good
proprietary tools leave room. It browses images, video, 3D models, vector art
and text as well as audio, lays them all out on the map, and runs on Windows,
macOS and Linux. Everything stays local.

**Selling comes later.** Plugins are nearly ready to sell and come first, so
the licence problem in §1 is not urgent — but it is written down first anyway,
because it decides which models are worth building on and that shapes
everything after it.

**Two install sizes, not fewer features.** A small, less accurate build and a
large, more accurate one. Nobody loses functionality because their disk is
small; they lose precision, and they are told which. This is a better answer
than the one this document originally gave.

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

Worth doing before any real weight is put on the music side — not because
selling is imminent, but because building further on a model that can never
ship is the expensive mistake. It is a day of work and needs no GPU time.

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

### Step 4b — vector art (2–3 days, alongside 3D)
Designers' files. Rasterise, then encode as an image — the same trick again.

- **SVG** — `resvg` (MPL-2.0) is fast, self-contained and renders correctly.
  Prefer it to `cairosvg` (LGPL) and `librsvg` (LGPL), which are usable but
  carry linking conditions worth avoiding in a closed product.
- **AI and EPS** — modern `.ai` files are PDF underneath, so `pdfium` (BSD)
  reads most of them. **Avoid Ghostscript: it is AGPL**, which is the worst
  possible licence to link into something sold.
- **PDF** — the same `pdfium` path, first page as the thumbnail.

Do not promise perfect fidelity. A thumbnail good enough to recognise and
embed is the requirement, not a print-accurate render.

### Step 5 — text (4–6 days)
Two separate features, and they should not be confused:

- **Search and map placement** wants a small sentence embedder — the BGE or E5
  families, MIT-licensed, a few hundred MB. Cheap and reliable.
- **Summarising** wants a local LLM. Qwen 2.5 (Apache-2.0) is the safer
  commercial pick; Llama's licence has conditions. Several GB, slow on CPU,
  and quality varies. Ship it as an optional download, not in the base install.

---

## 3b. Windows, macOS and Linux

Measured on 2026-09-09, not estimated:

    8 of 56 Odin files touch the Windows API
    2,419 lines of 22,878 — about 11%
    320 Windows API calls in total

**The other 89% is already portable.** Odin and raylib both run on all three.
The Python side is portable already: two places check `os.name`, and both are
handled correctly today.

What has to be rewritten, easiest first:

| File | Lines of Win32 | What it does | Porting it |
|---|---|---|---|
| `recycle.odin` | 10 calls | send to the recycle bin | Easy. Trash on macOS, the XDG trash spec on Linux. |
| `clipboard.odin` | 31 | copy files and text | Easy for text — raylib does it. File clipboard is per-OS. |
| `dragimage.odin` | 34 | the picture under the cursor while dragging | Cosmetic. Can ship without it at first. |
| `liveresize.odin` | 35 | keep drawing while the window is resized | Windows solves a Windows problem here. The others may need nothing. |
| `subprocess.odin` | 40 | run the Python jobs, read their output | Moderate. `posix_spawn` plus pipes; the shape stays the same. |
| `titlebar.odin` | 78 | the custom title bar | Moderate — **or free**, by using native decorations off Windows. Recommended. |
| `dragdrop.odin` | 88 | **drag a file out into another app** | The hard one. macOS needs `NSDraggingSource`, Linux needs XDND. |

`dragdrop.odin` is both the hardest to port and the most valuable feature for
every audience named above — dragging a clip into Premiere, a texture into
Blender, a reference into Figma. Budget for it properly rather than hoping.

Also: four `.bat` scripts need shell equivalents, and the Premiere panel is
Windows and macOS only, which Adobe decided, not us.

**Rough estimate: 2–3 weeks**, most of it in drag-and-drop and packaging. Best
done *after* the file kinds are general (Step 1) and *before* the code grows
much more Windows-specific.

---

## 3c. Two builds, small and large

Chosen deliberately over cutting features. Everyone gets every feature; what
changes is how much precision and disk it costs.

|  | Small | Large |
|---|---|---|
| Runtime | ONNX Runtime | PyTorch + CUDA |
| Models | quantised, int8 | full precision |
| Rough size | 300–600 MB | 6–10 GB |
| Speed | CPU-usable | much faster with a GPU |
| Accuracy | lower, and **stated** | the measured numbers |

Two things this must not do:

1. **Pretend they are the same.** The app should say which build it is and what
   that costs. "Small build: about 5% lower tagging accuracy" is honest and
   fine. Silence is not.
2. **Split the caches.** An embedding made by the int8 model is not comparable
   to one from the full model. Cache keys must include which build made them,
   or a user who upgrades gets a silently corrupt map. This is exactly the
   class of bug that has already bitten twice here.

The conversion work is the unknown. Most of these models export to ONNX
cleanly; some do not, and finding out which is the first task.

---

## 4. The things that will actually hurt

Ranked by how likely they are to sink it, not by how hard they are.

1. **Install size — now a build choice, not a cut.** See §3c. The large build
   stays large and honest; the small one exists so nobody is turned away by a
   6 GB download. The risk moves from "too big to sell" to "two builds to keep
   in step", which is a better problem but not a free one. The cache-key trap
   in §3c is the part that will bite.
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
5. **Scope, which is now wider.** Serving 3D artists, designers, editors and
   music people means five sets of file formats, five sets of expectations, and
   competitors in each: Adobe Bridge, Eagle, Soundly, Connecter, Kitbash
   managers. **The map is the thing none of them have.** Lead with it, and
   resist becoming a worse version of any one of them.
6. **Three platforms triples the testing.** Every check that exists today runs
   on Windows only. `--selftest` and friends have to run on all three, ideally
   automatically, or the ports will rot between releases.

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
| Step 1, general file kinds | 2–3 days |
| Step 2, images | 3–4 days |
| Step 3, video | 2–3 days |
| Step 4, 3D | 4–6 days |
| Step 4b, vector art | 2–3 days |
| Step 5, text | 4–6 days |
| macOS and Linux | 2–3 weeks |
| The small ONNX build | unknown, likely 1–2 weeks |
| Packaging and installers, three platforms | unknown |

**Six to eight weeks** for everything on the map on Windows, plus two to three
more for the other platforms. The two unknowns at the bottom are genuine — they
could add as much again, and neither can be estimated honestly until the first
model is actually converted and the first .app is actually built.

---

## 7. The first three things to do

Selling is not imminent, so these are ordered by *what would waste the most
work if it turned out badly*, not by what is most urgent.

1. **Prototype the image encoder on a folder of images, with no UI at all.**
   Embed, project to 2D, and measure whether the neighbours make sense — the
   way `sfx_map_bench.py` already does for effects. Two days.

   This is first because **the whole product rests on one claim**: that a map
   of files placed by content is genuinely useful. It is proven for audio. It
   is only assumed for images, and the effects map measured 16.2% where the
   encoder knew 32.7%, so the projection step is not free. If images map badly,
   that is worth knowing before six weeks go into it.

2. **Retrain on CLAP alone and compare.** One day, no GPU. Decides whether the
   music side can ever be sold, and therefore whether to keep investing in it.

3. **Convert one model to ONNX and measure both size and accuracy.** The small
   build in §3c is the difference between a product people will download and
   one they will not, and every estimate about it is currently a guess.

Steps 1 and 3 are both *experiments with a number at the end*, and both can be
thrown away cheaply. That is the right shape for the first work on something
this size.
