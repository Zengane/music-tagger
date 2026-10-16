# Music Tagger — notes for Claude sessions

Desktop app for finding the right file in a big library of music, sound
effects, video, images, 3D and documents. UI in Odin + raylib (`ui/`).
Analysis in Python jobs (`*_job.py`, `mtag/`), started by the app and read as
NDJSON on stdout. Read `README.md`, `docs/overview.md` and `HANDOVER.md` once.
Open issues: `docs/audit-2026-10.md`. Model notes: `docs/audio-models.md`,
`docs/model-assessment-2026-10.md`.

## Owner's rules

- **Talk plainly.** Short ASD-STE100 style: what you did, did it work, what
  the owner does next. Decisions: 2 options max, with your pick.
- **Correct over fast.** Measure before and after; say the numbers.
- **Ask before a workaround** when the requested approach is blocked.
- **Commercial licences only** for any model or data that ships. Check
  `docs/model-licences.md`. MuQ / MuQ-MuLan / MERT are CC-BY-NC (music side
  only, known issue). No Qwen-Audio, Audio Flamingo or other NC models.
- **Never send keystrokes to Premiere.** Talk to it only through the Zen Drop
  panel (HTTP on 127.0.0.1, `ui/premiere.odin`, `premiere/ZenDrop`).
- **The owner uses the app while you work.** Do not build `MusicTagger.exe`
  (build.bat needs the app closed), do not run GPU jobs on their library, do
  not touch `H:\`, `cache/`, `model/`, `prefs.json` without asking.
- **Nothing is written to the library until the user presses Save.** Keep it.
- Commit to the working branch as you go; push only when asked. Commit
  messages end with the `Co-Authored-By: Claude …` line.

## Building and testing without disturbing the owner

- Odin is at `C:\Odin\dist\odin.exe` (not on PATH).
  `odin check ui` and `odin check ui -target:linux_amd64` for type checks.
- Build a test copy into the scratchpad, never over `MusicTagger.exe`:
  `odin build ui -out:<scratch>\run\mt-check.exe -o:minimal`.
  The exe uses its own folder as the project root, so give that folder a
  junction `venv` → the repo's `venv` and copies of `*.py` and `mtag/`.
  Then run its headless checks there on generated files (ffmpeg makes
  test audio): `--cachecheck`, `--filingcheck <abs path>`,
  `--rescancheck`, `--selftest`, `--premiere-send <file>` (with
  `ZENDROP_PORT` set to a stand-in panel; the real panel is on 47821).
- Pass absolute paths to the checks.
- Line endings: the repo is LF. Some working files are CRLF on this PC.
  Keep each file's line endings as they are. Check with `git diff --stat`
  that no file is rewritten whole.
- GPU: RTX 3070 Ti, 8 GB. Never load more than one large audio model at a
  time. Embed **model-major** (one model over every file, then the next) —
  see `FusionEncoder.prefill` in `mtag/encoders.py`. File-major with three
  models spills VRAM and runs ~40× slower.
- Cache vectors per model (`mtag/dataset.py` `EmbeddingCache`, keyed by
  path + size + mtime). A second run must cost nothing.

---

## Current task: sound effects that sort themselves (one click)

### What the owner wants

1. **No tagging by hand first.** One click on a folder of effects does
   everything: analyse, group, name the groups, lay out the map. The owner's
   effects are messy, and many will be **game sound effects with internal
   names** (`sfx_npc_03b.wav`, `Play_Amb_Lp_02`, numbered banks) that say
   nothing at a glance.
2. **The app lumps similar sounds together** by what they sound like, so
   the owner can find one exact sound by **hopping from one effect to the
   next nearest one** until it is the right one.
3. **The Sound tab of the Map view must be good.** Today it is
   underwhelming.

### What exists today (verified 2026-10-01)

- Library: `H:\Media Browser\Mega Music Pack`, 8,688 audio files:
  **6,568 effects** under `SFX\`, 2,120 music tracks. Effects are marked
  `is_sfx` by folder (`ui/scan.odin` `add_track`) or by a sidecar override.
- **Map → Sound for effects** (`ui/nodes.odin` ~640-690):
  - Until the user presses "Build / update SFX sound map", dots are placed
    by **8 waveform measurements** (length, loudness, brightness, bass,
    punch, attack, build, sustain) with PCA — `ui/soundmap.odin`. This is
    crude, and it is what the owner mostly sees.
  - The button runs `sfx_map_job.py`: audio embeddings (general CLAP on
    Fast, PE-AV on Balanced/Best, `mtag/profiles.py`), UMAP
    (`n_neighbors=5`, `min_dist=0`), and region names from ~80 text
    phrases (`CONCEPTS`). It does **not** use filenames. It embeds
    file by file.
  - The settings say Auto, which picks Best (PE-AV large). **PE-AV has never
    been downloaded or run on this PC.** Existing effect vectors are general
    CLAP (`cache/clap-sfx-v1`, 6,577 files).
- **"Find more like this"** (right-click) sorts by `feature_distance` on the
  same 8 crude measurements (`ui/search.odin` `.Similar`), **not** on
  embeddings. It does not help with hopping between similar sounds.
- **Effect tagging** (`sfx_job.py`): filename rules + length (one-shot,
  loop, tail) + AST AudioSet classes folded into the app's words by
  `mtag/sfxtax.py` + PE-AV zero-shot (scaled down by `ZS_WEIGHT`). The audit
  says it re-embeds every file on every run (`docs/audit-2026-10.md` §2.3).
  Nothing learns from the user.
- **Measurement already exists:** `sfx_map_bench.py` (families from the
  library's own CamelCase filenames, 93 families, 1,057 labelled files).
  Nearest neighbour from the same family, out of all 6,568:
  chance 0.16% · general CLAP full vector 32.7% · current map 16.2%.

### Direction (proposed; measure each step, change it if numbers say so)

1. **One click: "Sort my effects".** From the Effects section or a folder's
   right-click menu. A single job, model-major and cached:
   embed with the profile's audio model (PE-AV) → group → name → lay out.
   It shows progress and can be stopped. A rerun only does new files.
   Fold the map build into it, so there is no separate button.
2. **Grouping without labels.** Cluster the embeddings (try HDBSCAN and
   agglomerative on cosine distance; compare on the bench). Each group gets
   a name from (a) the best-matching text phrase from the audio model, and
   (b) filename tokens **only when they agree across the group** (split
   CamelCase, `_`, digits; drop counters and game prefixes). For game
   sounds, audio decides and names follow. Store groups in a cache file,
   not in sidecars. Groups become tags only when the user accepts them
   (one click per group, or "accept all"), so Save still means something.
3. **Hopping.** A "Sounds like this" strip in the preview panel: the 10-20
   nearest effects by embedding (cosine), each one click to play. Clicking
   one makes it the new centre. Arrow keys move along the strip. Make
   "Find more like this" use embeddings when the file has one, and fall
   back to the 8 measurements only when it does not.
4. **The map.** Effects place by embedding (UMAP as now, or better if the
   bench says so), coloured by group, with group names as signposts. Hover
   plays. Clicking a dot shows its neighbours. The 8-measurement layout
   stays only as the fallback before analysis.
5. **Learn without hand tagging, later.** Folder names and consistent
   filename families are weak labels for free: train small probes on the
   embeddings (as the music side does in `mtag/probes.py`) and keep only
   tags whose measured precision is good enough. Accept/reject in the UI
   feeds this later.
6. **Long recordings and banks** (one file, many sounds): the split job
   exists (`sfx_split_job.py`). PE-A-Frame (Apache-2.0) can find where a
   sound is. Later.

### Acceptance

- One click on the 6,568 effects finishes without other steps. With PE-AV
  on the GPU, measure and report the time. A second run takes seconds.
- `sfx_map_bench.py` on the new vectors and layout: report the encoder
  score and the map score next to 32.7% / 16.2%. The map must improve.
- Hopping: the owner picks a sound, and the strip's first 5 sound like it.
  Report the bench's neighbour score for the strip (no projection: it
  should be near the encoder score).
- Works on a folder with meaningless names (test: copy 200 effects, rename
  them `sfx_0001.wav`…; groups and map must look the same).
- No new model unless its licence allows commercial use; add it to
  `docs/model-licences.md`.
- Update `docs/` and this file when done.

### Status 2026-10-01 (done; details in `docs/sfx-map.md`)

- The owner asked for **no new buttons**: everything is in Map → Sound with
  Effects, the same way music works. One in-tab button ("Sort N effects by
  sound" / "Map N new effects") and **Undo** (swaps with
  `model/sfx-soundmap.prev.json`). No preview-panel strip; hopping is on the
  map: click a sound, Right / Left.
- **Encoder: general CLAP, not PE-AV**, by measurement (CLAP 71.9%, PE-AV
  small 67.5%, large 67.0% on the labelled set). PE-AV now loads in bfloat16:
  in float16 it returned NaN for most effects.
- **The old bench was wrong about the map**: it scored the plane by cosine.
  By distance the old UMAP map was 25.2%, not 16.2%. New t-SNE map 30.8%;
  hopping neighbours 32.7% (= the encoder).
- Groups: Ward, ~40 per group, 164 on the library. Renamed copies give the
  same groups, neighbours and map.
- Full run with cached vectors 26 s; rerun 3 s.
- Not done: accepting a group as tags; probes on folder names; banks.

---

## Downloads (yt-dlp), done 2026-10-01

- Screen: `ui/downloads.odin` (button in the top bar). Job:
  `download_job.py` (probe / run), names: `mtag/downloads.py`. Standard
  library only. Full notes: `docs/downloader.md`.
- yt-dlp: `-U` on every start; installed into `bin\` with curl when missing.
- Checks: `tests_download.py` (offline), and
  `mt-check.exe --downloadcheck <empty folder> <link> [--run 3] [--library]`
  (hidden window, real links, screenshots in `work\`).
- Downloads go only to the folder the owner picks. Game tags are added
  unsaved; Save writes them.
- Default audio is M4A (YouTube AAC, unconverted): Premiere does not open
  Opus. Finished cards in another format offer "Replace N as M4A".
- Not done: other sites than YouTube untried; a full-OST video downloads whole
  even when only some chapters are wanted.

---

## Releases, done 2026-10-16

- GitHub: `https://github.com/Zengane/music-tagger`. Release files:
  `MusicTagger-Setup.exe` (Inno Setup, per user, no admin, into
  `%LOCALAPPDATA%\Programs\MusicTagger`) and `MusicTagger-windows-amd64.zip`.
- Build them without touching the owner's exe: build into the scratchpad,
  then `make_release.py --exe <scratch exe> --out <scratch dir> --installer`.
  Installer script: `installer/MusicTagger.iss`. Inno Setup is installed per
  user (`%LOCALAPPDATA%\Programs\Inno Setup 6`).
- Test: install with `MusicTagger-Setup.exe /VERYSILENT /DIR=<scratch>`, run
  `MusicTagger.exe --selftest` there, then `unins000.exe /VERYSILENT`.
