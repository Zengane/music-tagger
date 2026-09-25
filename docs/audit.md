# Audit — 2026-09-24

What was checked, what was fixed, and what is still open. Written at the start
of the overhaul, after porting the app to macOS and Linux and adding images,
video, 3D models and documents.

Each item says how much it matters (**High**, **Medium**, **Low**), what to do,
and whether it is **Fixed** or **Open**.

---

## 1. Bugs found and fixed

| | Item | Status |
|---|---|---|
| High | **Tag counts pointed at freed memory.** `add_tag_to_track` used a string from the job's parsed JSON as a map key. That memory is freed at the end of the frame, so after any Analyze the rail could show blank or garbage names ("???U") under "Not in the tag library". This affected music tagging on Windows too. | Fixed (`ui/tagger.odin`) |
| Medium | **A flaky test.** The montage test used ffmpeg sources that pick a random seed each run, so it failed about one run in five. | Fixed |
| Low | `tests_filing.py` ran `venv\Scripts\python.exe`, so it could not run on macOS or Linux. | Fixed |

## 2. Tests that are out of date (Open)

These fail today. They failed before this work too. Each one needs a decision
about which side is right: the test or the code.

| | Test | What is wrong |
|---|---|---|
| Medium | selftest: "rescanning discards unsaved changes" | The rescan now *keeps* unsaved edits on purpose (`merge_scan_result`). The test still expects them to be dropped. One of the two is wrong. My pick: the code is right; change the test. |
| Low | selftest: "tags became anchors", "it agrees with tags already applied" | These need your personal `tag_library.json`, which is not in the repository. They should skip, not fail, when it is missing. |
| Low | `tests.py`: "the source mood folder itself is left alone" | Filing now removes empty folders. The test was written before that. Change the test. |

## 3. macOS and Linux

**Done:** the app builds and runs on Linux (tested under a virtual display), and
the code type-checks for Windows, Linux, Intel Mac and Apple Silicon Mac. The
seven Windows-only files keep their code unchanged; each has a `_posix`
partner. Fonts, Python, ffmpeg, the trash, the clipboard and "show in folder"
all work per platform. `setup.sh`, `diagnose.sh` and `build.sh` match the
Windows `.bat` files.

**Not tested here:** a Mac build and a Windows build (both only type-checked),
and anything with a GPU.

| | Item | What to do | Status |
|---|---|---|---|
| High | **Dragging files out of the window** works only on Windows. On macOS and Linux a drag copies the files to the clipboard and says so. | Linux needs an XDND drag source (X11); macOS needs `NSDraggingSource` through the Objective-C runtime. About a week together. The roadmap already calls this the hard part. | Open |
| High | **No macOS app bundle, signing or notarisation.** Gatekeeper will block an unsigned download. | Build a `.app`, sign with a Developer ID, notarise. Needs an Apple developer account (99 USD/year). | Open |
| Medium | **PyTorch dropped Intel Macs.** The AI features on macOS need Apple Silicon and macOS 14+. | Nothing to fix; it is stated in the README and in `setup.sh`. The small ONNX build (roadmap §3c) would bring Intel Macs back. | Open |
| Medium | The audio encoders use CUDA or the CPU, never the Apple GPU. The new media models do use it. | Try MPS for CLAP and MuQ on a Mac; MuQ may need ops MPS lacks. | Open |
| Low | Colour emoji do not draw on macOS or Linux: those systems ship bitmap emoji fonts, which raylib's font loader cannot read. The plain stars (★ ☆) now fall back to the regular font; ⭐ and 🌟 still show as "?". | Bundle a small outline emoji font (Noto Emoji, OFL) if the favourite tags matter off Windows. | Open |
| Low | Copying files on Linux needs `xclip`, `xsel` or `wl-copy` installed. | The app says so when none is there. | Open |
| Low | The Premiere panel installer is a `.bat`, and its helper `ZenDropSend.exe` is Windows-only. | Only matters if Zen Drop should work from a Mac. | Open |

## 4. Speed

| | Item | What to do | Status |
|---|---|---|---|
| High | **Effects tagging runs one file at a time on the GPU**, and decodes every file twice (8 kHz for length, 16 kHz for the model). | Batch 16–32 files per model call; decode once at 16 kHz and measure length from that. Large effects libraries would tag several times faster. | Open |
| Medium | **Music tagging decodes each track three times** — once per encoder in the fusion — and runs ffprobe three times. | Decode once per sample rate per file, or seek to the windows actually used. Small next to GPU time, but it adds up on a CPU-only machine. | Open |
| Medium | **Every vector is its own small file** (`cache/<model>/<hash>.npy`). Ten thousand files across four models is forty thousand files. On Windows, Defender scans each one, which slows the search server's start and the maps. | Keep one matrix per model with an index beside it, appended as files are analysed. | Open |
| Low | The media job loads its three models on every run (5–10 s), even for one file. | Keep one worker running while the app is open, the way the search server works. | Open |
| — | Long videos were decoded frame by frame for the motion pass: minutes for an hour of 4K. | Videos over two minutes are now read by keyframe, and frame-level tags are not claimed for them. | Fixed |

The native front end itself is fast: about a millisecond a frame, and every
keystroke in search is one pass over the list. Nothing to fix there.

## 5. Licences

| | Item | Status |
|---|---|---|
| High | **The music tagger still depends on MuQ (CC-BY-NC).** It cannot be sold as it is. The roadmap's step 0 — retrain on CLAP alone and measure — is still the first thing to do. It needs your library and your cached embeddings, so it runs on your PC. | Open |
| — | Every model added in this work allows commercial use: SigLIP 2 (Apache-2.0), Florence-2 (MIT), multilingual E5 (MIT). So do the new libraries: Pillow, pypdfium2/PDFium, python-docx, trimesh. See `docs/model-licences.md`. | Done |
| Medium | Hugging Face was not reachable from the environment this was built in, so the licences were confirmed from search results and from the transformers source, not by reading each model card on the day. | Read the four model cards once before a release and add the date. | Open |
| Low | `pillow-heif` was left out on purpose: its wheels bundle LGPL and GPL codecs. HEIC photos are read through ffmpeg instead, when its build supports it. | Done |

## 6. Code health

| | Item | What to do |
|---|---|---|
| — | The old browser UI (`app.py`, `desktop.py`, `launcher.py`, `templates/`, the two webview `.bat` files) sat at the top level. | Moved to `legacy/` on 2026-09-25; it still runs from there. Delete the folder, and `flask`/`pywebview` from requirements, once nobody needs it. **Done.** |
| Medium | `ui/app.odin` is 3,500 lines and holds the top bar, the list, the inspector, the dock, the menus and the key handling. | Split it along those lines when next touched. No behaviour change. |
| Low | Development scripts with personal paths sit at the top level: `bakeoff.py`, `sweep.py`, `work_bench.py`, `fix_tags.py`, `drops.txt`. | Move them to `tools/`. |
| Low | `premiere/ZenDrop/bridge/ZenDropSend.exe` is a compiled binary in git. | Build it in the release step instead. Also: decide whether Zen Drop stays in this repository before it is made public (from the handover). |

## 7. The new media analysis — what to check on real files

The measured tags (green and blue screen, alpha, black and white backgrounds,
colours, flashes, fades, cuts, loops, vertical, 4K, frame rate, HDR) have tests
on files made for the purpose, and pass them. **The model tags have never seen
a real file**: the models could not be downloaded here. The whole pipeline was
run through the real transformers classes with tiny random models, so the code
paths are checked, but not the answers.

| | Item | What to do |
|---|---|---|
| High | **The zero-shot thresholds are guesses.** SigLIP's scores are not comparable between concepts. | Tag a sample of your own files by hand — say 200 across memes, VFX elements, B-roll and stock photos — then measure precision per tag and set each threshold where it earns it, the way the music tagger's were set. Until then, the suggestions list is the useful part. |
| Medium | Florence-2 reads meme text well, but dense or small text less well. | If documents and screenshots matter, RapidOCR (Apache-2.0, ONNX) is the next step up. |
| Medium | Sky-only photos can read as a blue screen: the sky is evenly lit and saturated blue. Foliage no longer passes for green screen (fixed, with a test). | Watch for it on real files; the model's "Sky" tag appears beside it. |
| Low | Video audio is not analysed: an explosion clip with its bang could also be tagged by the effects model. | Run the AudioSet tagger on video soundtracks. |

## 8. What was built in this session

- The app on macOS and Linux (§3).
- Analysis of images, video, 3D models and documents: `media_job.py` and
  `mtag/media/`. Measured tags, SigLIP 2 tags, Florence-2 captions and OCR,
  E5 text vectors, 3D models drawn from four sides without OpenGL, documents
  read and sorted into kinds.
- Search by description across every kind of file: `search_server.py` and
  `ui/semantic.odin`. It uses what files look like, sound like and say.
- In the app: Images / Video / 3D / Docs filters, thumbnails in the grid, the
  inspector and the player area, captions and OCR text shown and saved to the
  sidecar, and a three-way split of Analyze.
- `setup.sh`, `diagnose.sh`, `build.sh`, and a release script that packages
  for the platform it runs on.

Tests added: `tests_media.py` (22), `tests_semantic.py` (6),
`tests_media_models.py` (2). All pass.
