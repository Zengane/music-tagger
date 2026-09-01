# Music Tagger v2 — Handover

Auto-tags a game-soundtrack library with Mood and Sound tags, writes them back as
TagSpaces sidecars, reads the game name off the filename or folder, and files
tracks into folders named after their primary mood.

- **Code:** `C:\Users\simsi\music-tagger-v2` (git, 6 commits)
- **Library:** `H:\Media Browser\Mega Music Pack`
- **Predecessor:** `C:\Users\simsi\music-tagger` — untouched, kept as reference
- **User:** Zengane. Video editor; the tags are editing cues, not musicology.

---

## Run it

```bat
cd "C:\Users\simsi\music-tagger-v2"
run.bat
```

Creates the venv on first run, then serves the review UI at `http://127.0.0.1:5000`.

| Command | What it does |
|---|---|
| `run.bat` | Review UI |
| `venv\Scripts\python.exe train.py "H:\Media Browser\Mega Music Pack"` | Retrain from sidecars |
| `venv\Scripts\python.exe bakeoff.py "H:\Media Browser\Mega Music Pack"` | Re-score all encoders |
| `venv\Scripts\python.exe fix_tags.py "<library>" [--apply]` | Rewrite tags missing from the tag library |
| `venv\Scripts\python.exe tests.py` | 96 checks |

**UI flow:** set *Folder* (music to tag) and *Library root* (`Mega Music Pack`) →
tick *untagged only* → Scan → Analyze all → review → tick *move into mood folders
on save* → Save all analyzed → Retrain.

Keys: `↑`/`↓` move, `Enter` save and advance, click a tag to toggle.

---

## Current state

Model: **fusion**, 4096-dim, trained on **878** tracks.

```
macro AP 0.597 · macro AUC 0.916 · precision 0.50 · recall 0.74 · 33 probes
zero-shot fallback: Loss, Romantic, Trappy, Wintery
```

Read that as: it suggests about three quarters of the tags the user would have
applied, and about half its suggestions survive review. It is a review tool, not
an unattended one.

### Which tags to trust

| Trust | Tags |
|---|---|
| Good (AP > 0.65) | Victory, Orchestral, Rock-Metal, Fantasy, Goofy, Oriental, Hype, Chill, Childish, Serene, Jazzy, Ambient |
| Middling (0.5–0.65) | Epic, Bombastic-Heavy, Awkward, Medieval, Funky, Weird, Adventure, Folk, Dreamy, Ominous, Electronic, Choir, Tribal, Tension |
| Check by ear (< 0.5) | Chiptuney 0.45, Melancholic 0.43, Hopeful 0.41, Beachy 0.37, **Build-Up 0.34**, **Mysterious 0.31** |

**Vocals is special:** precision 0.92, recall 0.37. It exists to filter tracks
*out* of an edit, so its threshold leans to precision (F-0.6 in
`probes.TAG_BETA`, against F-1.5 everywhere else). When it fires it is almost
always right; it misses about two thirds of vocal tracks. Only 30 examples — the
honest fix is a dedicated vocal detector (source separation on the vocal stem),
not more threshold tuning.

### The new batch

`Mega Music Pack/Untagged/` holds **925 tracks** the user dropped in and has not
tagged yet. That is the immediate job. Game detection covers 100% of it.

---

## How it works

```
audio ── ffmpeg ──> 12 windows spread across the whole track
                          |
              muq-mulan + muq + clap-music (frozen)
                          |
              mean + std pooled, concatenated, L2 normalised   (4096-dim)
                          |
        ┌─────────────────┴──────────────────┐
   probe per tag                      zero-shot text
   (>= 12 examples)                   (rarer tags)
```

One independent logistic regression per tag, trained on the user's own sidecar
labels. `C` picked by cross-validation, `class_weight="balanced"`, per-tag
thresholds tuned on out-of-fold predictions.

### File map

```
mtag/taxonomy.py   tag vocabulary, game phrases, skip rules — most edits land here
mtag/sidecar.py    TagSpaces sidecar read/write, tag aliasing
mtag/audio.py      ffmpeg decode, whole-track windowing, file discovery + skipping
mtag/encoders.py   the four encoders and the fusion wrapper
mtag/dataset.py    label collection, embedding cache, cache re-keying on move
mtag/probes.py     per-tag training, CV, threshold selection, TAG_BETA
mtag/model.py      the saved tagger, zero-shot fallback heads
mtag/gametag.py    game name from filename or folder
mtag/organize.py   mood-folder filing
bakeoff.py  train.py  fix_tags.py  app.py  tests.py
```

---

## Why it is built this way

### v1 was broken five ways

v1 asked zero-shot CLAP "does this sound like *goofy silly playful cartoon
comedic funny music*?" and thresholded the answer.

1. **It only heard 10 seconds.** `laion/clap-htsat-unfused` is configured
   `max_length_s=10, truncation="rand_trunc"`. v1 decoded 60s; the processor
   discarded fifty of them at random.
2. **It ran on the CPU.** The venv had `torch==2.10.0+cpu`. `run.bat` probed
   `cuda.is_available()` *before* installing torch, so the CUDA branch misfired.
3. **Min-max per category** forced one mood to 1.0 and one to 0.0 in every file.
4. **Thresholds fit on positives only** — 20th percentile of positive logits,
   with negatives never consulted.
5. **The vocabulary is personal.** Build-Up, Awkward, Bombastic-Heavy are editing
   cues. No zero-shot model knows what they mean here.

Meanwhile the library already held ~857 hand-tagged tracks. v2 treats that as
training data. That is the whole idea; don't regress to zero-shot.

### The encoder was chosen by measurement, not by paper

Scored on the library's own labels (`results/bakeoff.json`):

| encoder | dim | macro AP | AUC | prec | rec |
|---|---|---|---|---|---|
| **fusion** | 4096 | **0.591** | 0.917 | 0.51 | 0.74 |
| muq-mulan | 1024 | 0.559 | 0.909 | 0.48 | 0.73 |
| clap-music | 1024 | 0.526 | 0.893 | 0.44 | 0.73 |
| muq | 2048 | 0.521 | 0.889 | 0.44 | 0.71 |
| mert | 2048 | 0.445 | 0.871 | 0.40 | 0.69 |

No single encoder won everywhere. MuQ-MuLan takes most tags; MuQ is better at
Fantasy, Ambient and Medieval; CLAP-music is much better at Chiptuney. Fusing
moved Fantasy +0.16, Medieval +0.13, Chiptuney +0.13.

**MERT is excluded on purpose:** +0.003 AP for another 2048 dimensions and
another pass over every file. Don't add it back without re-measuring.

### Other settled decisions

- **Thresholds lean to recall** (F-1.5). A missing tag is invisible in TagSpaces;
  a wrong one is one click. `Vocals` inverts this — see above.
- **Folder names are not labels.** They agree with the sidecars 822/858 of the
  time; the 36 disagreements are deliberate retags.
- **Game tags are never predicted from audio.** Two Mario Galaxy tracks sound
  nothing alike. Read from the filename or folder, or not at all.
- **Folders outrank filenames** for game detection — a drop is named after its
  game. But a *known* game in a filename beats a *guessed* folder name, so
  `JimmyHere music/` doesn't swallow the Mario Galaxy tracks inside it.
- **Outermost folder wins**, not innermost: `Bayonetta/DISC 3/` → Bayonetta.
- **Moves are planned then confirmed.** Sidecars travel with the track,
  collisions are refused, and folders the user made are never deleted.

---

## Library facts worth knowing

- ~1783 audio files: ~858 tagged and filed by mood, 925 in `Untagged/`, 40 in `SFX/`.
- Mood folders: Adventure, Awkward, **Build up** (not "Build-Up"), Chill, Epic,
  Goofy, Hype, `Hype - Ominous`, Melancholic, Mysterious, Ominous, Serene,
  Tension, Victory. Bombastic-Heavy, Hopeful and Loss have no folder yet.
- **SFX is skipped everywhere** until it gets its own model — one-shot hits and
  drones don't fit a music taxonomy. Opt out with `skip_dirs=()`.
- **"Audio Extracted" files are skipped.** The user renders stems out for
  Audition and they land next to the original.
- **Tag aliases** (`taxonomy.TAG_ALIASES`, `GAME_ALIASES`): four names were typed
  into sidecars that the tag library doesn't contain. `fix_tags.py --apply` has
  been run, 16 sidecars corrected, nothing unknown remains. Reading still maps
  them so this can't silently recur.
- **`Penny-Big-Breakaway` is canonical**, *not* the tag library's
  `Penny's-Big-Breakaway`. TagSpaces wouldn't match the apostrophe form, so the
  user renamed it: 44 files use the short form, 0 use the library's. Generated
  tags drop apostrophes for the same reason.
- **N64-Zelda means Ocarina + Majora** deliberately — similar OSTs, one tag. Do
  not retag those 72 files. `legend of zelda` is *not* a match phrase; it used to
  be, and it would have put 123 Breath of the Wild tracks on that tag.

---

## Traps

- **Never let pip resolve torch freely.** `muq` → `x_clip` → `torchvision` will
  pull a CPU wheel over the CUDA build, silently, and everything still "works" at
  roughly 40x slower. `requirements.txt` pins `+cu130` local versions so pip
  refuses the substitution. This is exactly how v1 lost the GPU. `tests.py`
  asserts CUDA is visible.
- **Python 3.12 only.** 3.13+ has no matching CUDA torch wheels.
- **The Windows console is cp1252.** Filenames contain `⧸`, `｜`, `＂` and
  Japanese. CLI entry points must call `console.init()` or one filename kills the
  whole run.
- **The Windows filesystem is case-insensitive** — it bit one test that created
  two files differing only in case.
- **transformers 5.x renamed CLAP's `audios=` to `audio=`** and moved the
  projected embedding onto `.pooler_output`.
- **Zero-shot uses `meta["text_slice"]`, not "the first half".** With three
  encoders stacked, the text-comparable block is columns 0:512 (MuQ-MuLan's mean
  half). Encoders declare this via `text_slice()`.
- **Restart Flask after editing `app.py`.** There is no reloader; a stale process
  cost time once already.
- **MuQ weights are CC-BY-NC 4.0.** Fine for a personal library, not a product.

---

## Caches

`cache/<encoder>/*.npy`, keyed by path + size + mtime. Moving a file re-keys its
entries (`dataset.rekey_caches`) so it isn't re-embedded.

`cache/fusion/` is a second copy of the concatenated vectors, written only by the
app (`app.py:_embed`); `train.py` and `bakeoff.py` skip it via
`caches_internally` and read the three part caches instead. Harmless, ~8 MB, and
it makes review one file read instead of three. Delete it freely.

Re-embedding the whole library costs roughly 40 minutes on the RTX 3070 Ti.

---

## Open items

1. **Tag the 925 tracks in `Untagged/`.** The actual job.
2. **Get the new game tags into TagSpaces.** 14 new games (Bayonetta, Terraria,
   TF2, VA-11-Hall-A, Wii-Sport-Resort, Legend-Of-Zelda-Breath-Of-The-Wild,
   Mario-Kart, Wario-World, JimmyHere, Orange-Lounge, Yosumin, Blasphemous,
   Hello-Baby, Mario-64), plus dropping the stale `Penny's-Big-Breakaway` entry.
   - `tsTagLibrary` lives in TagSpaces' Chromium localStorage
     (`AppData\Roaming\TagSpaces\Local Storage\leveldb`) alongside locations,
     settings and history. **Do not write to it** — corruption risk, and the app
     holds a lock while running.
   - `.ts/tsl.json` in the location auto-loads per-location tag groups, refreshed
     by Tag Library → *Reload Location Tags*. The installed build (6.9.2)
     references `tsl.json`, but the feature is **Pro-gated** and it is unconfirmed
     whether the user holds a Pro licence. **Ask before building this.**
   - Fallback that works on any edition: regenerate the export JSON and import it
     by hand. Nothing is written yet; the decision sits with the user.
3. **Vocals recall is 0.37.** Needs a real vocal detector, not more tuning.
4. **SFX tagging** — deliberately out of scope; needs its own taxonomy and model.
5. Untrainable tags: Loss (8), Romantic (7), Trappy (6), Wintery (5). The
   zero-shot fallback fires them at about 3x prevalence for manual review. They
   improve on their own as the user tags more.
