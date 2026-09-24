# Music Tagger — handover for a new session (2026-09-24)

The full handover for all of the owner's tools lives in the private repo
`Zengane/zen-text` (`HANDOVER.md`). This file holds what matters here.

## 0. Working rules (the owner's, all still in force)

- **Talk plainly.** Owner wants short, plain English (ASD-STE100 style): what
  was done, did it work, what they do next. Decisions: at most 2 options, with
  your pick. One recap at the end of a task, not running commentary.
- **Correct over fast.** Do it properly rather than shipping something shaky.
- **Ask before a workaround.** If an API blocks the requested approach, ask
  before switching to a different approach.
- **Commercial licences only** for any model, font or data shipped in a product.
  Give credit where the licence asks (CC-BY etc.).
- **Never send synthetic keystrokes to Premiere.** A stray key once trimmed a
  caption. The owner's Premiere keymap is customised (Undo = Alt+Z). Message
  window handles directly or use ExtendScript.
- **No live tests while the owner is using the PC** unless they say so. Mouse
  clicks only over Premiere's own window (a click once landed on another app).
  Studio UI tests run off-screen (see §2.6).
- **Never cudaMalloc/cudaFree in a Premiere GPU render path** (froze Premiere,
  needed a hard power-off). Allocate through PrSDKGPUDeviceSuite.
- **Do not close the owner's After Effects**; do kill `AfterFX.exe -m` (the
  hidden MOGRT render helper) before installing a plug-in, it locks the .aex.
- **Git:** identity is global `Zengane <332393540+Zengane@users.noreply.github.com>`.
  Commit messages end with `Co-Authored-By: Claude …` line. Commit/push only
  when asked, or as routine backup of work you did in that session.
- **Secrets never go to GitHub**: `%APPDATA%\Zengane\signing`, licensing test
  keys (`*.b64`, `.dev.vars`, `.wrangler/`), `license.tok`, HF / API tokens,
  `%APPDATA%\Zengane\Whisper Captions\settings.json` (holds an HF token).

---

## 4. Music Tagger (next big project; cloud sessions may work on it)

Repo `Zengane/music-tagger` (private, branch master; history rewritten on
2026-09-24 so every commit is by Zengane with the no-reply email). Desktop app
in Odin + raylib, audio analysis in Python; read its `README.md` and
`docs/overview.md`. The working copy has an uncommitted README change that is
only line endings.

Owner's goals for the overhaul:
- Tag **images, video, 3D models and documents** (PDF, DOCX), not only audio.
- Models must allow **commercial use**. Starting candidates (verify each
  licence before use): SigLIP 2 (Apache-2.0) for image tags, Florence-2 (MIT)
  for descriptions, TransNetV2 (MIT) for video cuts + image models on key
  frames, render 3D models to a few pictures then tag them, pypdf / python-docx
  for text + a small text-embedding model (e.g. BGE, MIT).
- **Film assets**: recognise overlays (alpha channel, black/white backgrounds
  for screen/add blends) and green/blue screens properly (colour analysis, no
  model needed), and tag them as such.
- A **yt-dlp** feature (Unlicense) that downloads files and files them into
  categories.
- Cloud sessions run Linux: they can write code, tests on sample files and
  licence research; Windows UI and GPU tests happen on the owner's PC.
- Before making it public: decide whether `premiere/ZenDrop` (a separate
  Zengane product) should leave the repo.

---


---

## 5. Session 2026-09-24 (cloud, Linux): what was done

Branch `claude/kind-allen-v29vjx`. Full list and open items: `docs/audit.md`.

- **macOS and Linux.** Windows-only Odin files renamed `*_windows.odin`, with
  `*_posix.odin` partners (`platform_posix.odin`, `subprocess_posix.odin`).
  Type-checks for all four targets; builds and runs on Linux (tested under
  Xvfb). `build.sh`, `setup.sh`, `diagnose.sh`. **Not yet:** drag-out on
  macOS/Linux (copies to the clipboard instead), a signed `.app`.
- **Media analysis:** `media_job.py`, `mtag/media/`. Measured tags + SigLIP 2
  + Florence-2 + multilingual E5, all commercial licences. 3D rendered with a
  numpy point renderer (no GL). Small/large builds via
  `MUSICTAGGER_MODEL_SIZE`. Thresholds in `mtag/media/vocab.py` are **guesses**
  until measured on real files; `media_vocab.json` overrides them.
- **Search by description:** `search_server.py` (resident, stdin/stdout) +
  `ui/semantic.odin`. Two or more plain words, or a query that finds nothing,
  also goes to the server.
- **UI:** file kinds, Images/Video/3D/Docs filters (only when present),
  thumbnails (`ui/thumbs.odin`, key = `hash_key`, same as the waveform cache),
  captions/OCR in inspector and player area, saved to the sidecar.
- **Bug fixed:** tag counts keyed by freed JSON strings (garbage names in the
  rail after Analyze) — affected Windows music tagging too.

### What the owner does next

1. Pull the branch on the PC, run `build.bat`, then
   `venv\Scripts\python.exe -m pip install -r requirements.txt` (new packages).
2. Run the tests: `tests_media.py`, `tests_media_models.py`,
   `tests_semantic.py`, and `mtag-test.exe --selftest`.
3. Point the app at a folder of memes, VFX elements and B-roll, press
   Analyze, and look at what it says. The first run downloads about 1.5 GB of
   models. Report the tags that are wrong; that is how the thresholds get set.
4. Decide the open questions in `docs/audit.md` §6 (delete the old web UI?)
   and §2 (which side of the three stale tests is right).

Nothing was tested with a GPU, on Windows, or on a Mac in this session.
