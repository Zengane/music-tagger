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

## 6. Session 2026-09-25 (cloud, Linux)

- **Profiles** (`mtag/profiles.py`): Fast / Balanced / Best / Auto; in the app
  under Settings → Analysis models; `python -m mtag.profiles` for the installer.
- **PE-AV** (Apache-2.0) for sound search and zero-shot effect categories on
  Balanced/Best. (The effects map moved back to general CLAP on 2026-10-01,
  by measurement: `docs/sfx-map.md`.) Music: `train.py --encoder
  fusion:clap-music+pe-av-base` to measure a MuQ replacement.
  Research and how to measure: `docs/audio-models.md`.
- Old browser UI moved to `legacy/`.
- Fixed: most settings never saved; Linux children not seeing app-set
  environment variables; non-ASCII search queries on Windows; video lengths.
- Stale tests brought in line with decided behaviour; `--selftest` passes in
  full on a sample library.

### What the owner does next

1. Pull, `build.bat`, then `venv\Scripts\python.exe -m pip install -r
   requirements.txt` (new: timm, and the packages from 2026-09-24).
2. Run the tests (list in README). `tests.py` fails "torch sees the GPU" only
   when torch is a CPU build — on your PC it should pass.
3. Try the app on a mixed folder; leave Settings → Analysis models on Auto.
4. When there is time: the measurements in `docs/audio-models.md` §4 and §5.

## 7. Session 2026-09-25, later (cloud, Linux): the UI overhaul — HANDOFF

The owner asked to stop using credits on this and hand off. This section is
the state of the UI overhaul, so any session (cloud or local) can pick it up.

### Done, built and tested here

- **Build stamp.** The title bar, the log and `--selftest` show
  `build <commit> · <date>`. `build.bat` passes the commit (read from `.git`
  when git is not on PATH, as with GitHub Desktop) and prints a large
  "BUILD FAILED — MusicTagger.exe was NOT updated" box on failure. The Browse
  button was already in the code; the owner's copy was most likely an old
  .exe. The stamp settles that question next time.
- **+ beside LIBRARIES opens the system folder picker directly** (typed path
  only where no picker exists).
- **Sidebar** (`ui/sidebar.odin`): LIBRARIES, SHOW (All, Music, Sound
  effects, Video, Images, 3D models, Documents, with counts — always listed),
  FOLDERS (a real tree, `ui/browse.odin`, counted per section), TAGS. Every
  section folds.
- **One browser instead of List + Grid** (`ui/browser.odin`, tiles in
  `ui/grid.odin`). A zoom slider (top bar, Ctrl+wheel, V key) goes from a list
  with columns Name / Tags / Type / Length / Size / Modified (click a header
  to sort, again to reverse) to tiles. Folders show as items (file-manager
  style) or everything flat — toggle in the top bar. Search looks under the
  current folder. Status line at the bottom. Backspace = up a folder.
  Video tiles scrub on hover (filmstrip). Double-click opens the big viewer.
- **Top bar** (`ui/toolbar.odin`): sidebar toggle, up, breadcrumb, search,
  sort (10 options + direction arrow), zoom, folders toggle, Browse/Map/Tag,
  Undo, Analyze, Save, panel toggle, settings. **Right-click the bar** to
  choose which controls it shows (saved in prefs). No overlaps at any width
  from 1040 to 2600 (`--windowcheck`).
- **Previews** (`ui/preview.odin`, `ui/viewer.odin`, `ui/video.odin`,
  `ui/viewer3d.odin`, `preview_job.py`):
  - images: large version (ffmpeg, cached), zoom/pan in the viewer;
  - video: real playback (ffmpeg frames + its audio through the normal
    player, so the dock transport and waveform work on video);
  - 3D: interactive viewer (drag turn, wheel zoom, right-drag move,
    wireframe, turntable). raylib loads glTF/OBJ/VOX; everything else is
    converted once to GLB: STL/PLY/OFF/3MF/DAE (trimesh), **Blockbench
    .bbmodel** and **MagicaVoxel .vox** (own converters,
    `mtag/media/bbmodel.py`, `voxel.py`), FBX/.blend/USD/ABC/3DS/X3D
    (Blender, when installed). Cinema 4D, 3ds Max, Maya, SketchUp, LightWave
    files are listed and tagged by name, and the preview says to export them.
    Model and PDF tiles get thumbnails rendered by the app itself.
  - documents: PDF pages (pypdfium2), text of .docx/.odt/.rtf, plain text
    files read directly.
- **Preview panel** (`ui/inspector.odin`): the file's preview on top, facts,
  what it shows, tags with a type-to-add box, markers/game for music, the tag
  buttons and model scores in folding sections (tag buttons folded for media).
- Looking at a picture no longer stops the music. The player shrinks to its
  transport in the Images / 3D / Documents sections.
- F12 saves a screenshot to `logs/` (useful for bug reports).
- Tests: `--selftest` all pass (browsing checks rewritten for folders);
  `tests_preview.py` new, passes; `tests_media.py` passes; Linux build,
  Windows object and macOS type-check all compile.

### Not done yet (in order)

1. **Settings overhaul** (task from the owner): a full settings page with
   sections — General (scale, scrubbing), Library (import options, rescan),
   Analysis & models (profile, and a list of **installed models with size and
   folder**: read the Hugging Face cache, e.g. a small `models_job.py` using
   `huggingface_hub.scan_cache_dir()`, plus where `model/tagger.pkl` is),
   Storage (sizes of `cache/*`, with Clear buttons), About (build stamp,
   credits/licences). Today `draw_settings` in `ui/app.odin` is still the old
   popover under the gear.
2. Not seen on screen yet: the big viewer (image zoom, video bar, PDF pages,
   text), video playback end to end, and the document preview. The code is
   in and compiles; check each with F12 screenshots under Xvfb.
3. Docs: README "What it does" / keys (B, V, Backspace, F12, right-click top
   bar), `docs/overview.md`, `docs/model-licences.md` (pypdfium2 is already
   listed; nothing new is downloaded).
4. Small: remember the last open folder; `tile_size` pref is now unused.

### For the owner

Pull, run `build.bat`, check the title bar says `build <new commit>`, then
`venv\Scripts\python.exe -m pip install -r requirements.txt`.

### Settings page — done (same day, second part)

`ui/settings.odin`, opened by the gear. Five sections down the left:
- **General**: interface size, silent scrubbing, reset the top bar, shortcuts.
- **Library**: include subfolders, rescan, show the library folder.
- **Models**: Auto/Fast/Balanced/Best, this computer's GPU and RAM and what
  Auto picks (from `python -m mtag.profiles`), and **every installed model**
  with what it is for, its size and a button to open its folder. Models are
  read from the Hugging Face cache (`HF_HUB_CACHE`, `HF_HOME/hub`, or
  `~/.cache/huggingface/hub`) plus the app's own `model/` folder.
- **Storage**: every `cache/` folder with its size and file count; the ones
  that are only pictures/conversions have Clear (asks "Sure?" first).
- **About**: build stamp, app/logs/python folders, ffmpeg found or not,
  credits and licences.
The scans run on a background thread when the page opens. Checked on screen
under Xvfb; `--selftest`, `--windowcheck`, Windows object and macOS check pass.

### Checked on screen (third part)

Video plays in the panel (frames advance, stops at the end, length learnt);
the big viewer opens and the arrow keys step through files; PDF pages and
.docx text show in the panel. Fixes made while checking: the viewer's
backdrop is solid; a silent video says so instead of "reading waveform…";
picking a section (Video, Images…) lists every file of that kind under the
current folder instead of making you open folders (All files keeps the
folder view); the preview panel follows the section.

Owner's PC note: the pull on 2026-09-25 did not go through (the old
build.bat ran). Check GitHub Desktop → History shows the newest commit
before building.

### Video playback (fourth part, ~$6 of credit left)

- Settings → General → "One click plays a video" (pref `video_click_plays`,
  default on). Off: a click shows the first frame, a double click plays.
  With it on, a double click opens the big viewer.
- The preview panel has video controls under the picture (play, scrub bar
  with a filmstrip frame on hover, time); the volume stays in the player.
- Clicking the video that is already open no longer restarts it.
- Fix: choosing a section while inside a folder with none of that kind goes
  back to the top instead of showing an empty list.
- `build.bat` reads the build code with `ui/build_id.py` and runs inside a
  window that stays open (it was closing instantly on the owner's PC).

The owner wants the image, video and text viewers overhauled further; video
first ("the player isn't very good feeling"). Ideas not done: controls
over the picture on hover, keyboard J/K/L and frame stepping, remembering
the position per video, smoother seeking (keep ffmpeg running and read ahead).

### Still to do (next session)

1. Not seen on this machine (no sound device here): video with sound, and
   the video bar's scrubbing in the big viewer. Check on the PC.
2. Small: the `tile_size` pref is unused (zoom replaced it).

Done since: README "Finding your way around"; the app reopens the folder you
were in (prefs `last_folder`, kept across rescans of the same library); the
self test no longer writes prefs.json (`prefs_frozen`).
