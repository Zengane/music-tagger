# Music Tagger v2 — Handover

Updated: 2026-09-06

## Project

- Repository: `C:\Users\simsi\music-tagger-v2`
- Native executable: `MusicTagger.exe`
- Music library used during development: `H:\Media Browser\Mega Music Pack`
- Predecessor project: `C:\Users\simsi\music-tagger` (reference only; do not modify).
- UI and application code are Odin in `ui/`; Python handles audio analysis, tagging, imports, filing, and SFX splitting.

The worktree is deliberately uncommitted and contains substantial user/Codex changes. Preserve all existing edits; do not reset or checkout files wholesale.

## Build and verification

Close `MusicTagger.exe` before rebuilding because Windows locks it.

```bat
C:\Odin\dist\odin.exe build ui -out:MusicTagger.exe -o:speed -subsystem:windows -resource:app.rc
C:\Odin\dist\odin.exe build ui -out:mtag-review.exe -o:speed
mtag-review.exe --selftest
mtag-review.exe --cachecheck work\cache-fixture
venv\Scripts\python.exe -m unittest tests_imports tests_sfx_map tests_tag_job tests_split
```

The latest pass completed these checks successfully. `--review-ui` renders hidden UI screenshots under `work/` for visual review.

## Current behaviour

### Startup, library caching, and imports

- Library snapshots are written under `cache/libraries/`. Startup loads the last snapshot immediately, then refreshes in a worker.
- External folder imports run asynchronously through `import_folder_job.py`. They copy audio and sidecars into the active library, preserving the source folder.
- Music lands under `Untagged/<pack>`; SFX lands under `SFX/Unsorted/<pack>`. Duplicate unchanged imports reuse an import receipt; changed or colliding imports receive a numbered folder.
- `Centralize imports` in Tagging copies legacy external references into the library. The source is retained.
- Import staging and receipt files live under `.music-tagger-imports`, which the scanner skips.

### Tagging and filing

- Tagging supports folder rows, multi-selection, and checkbox-origin drag painting. File-row drags do not start selection painting.
- Right-click selected Tagging items exposes **Move to SFX** and **Move to Music**. This persists `musicTaggerKind` in the sidecar, updates filters immediately, then opens the normal filing preview.
- Explicit type overrides survive rescans. Reclassification is not automatically applied to old packs; select the affected files and use the context action.
- Filing is always two-phase: plan, show preview, then apply. Audio and sidecar collisions are refused.
- Music files file into their primary mood or `Untagged`. SFX files file into fixed categories such as `SFX/Impacts`, `SFX/Transitions`, `SFX/Interface`, etc., with `SFX/Unsorted` as fallback.

### Tagging performance and markers

- Cached AI tagging avoids loading encoders/PyTorch. Missing vectors are prefetched model-by-model to keep VRAM lower.
- Tracks missing a mood receive their highest scoring mood; existing moods and SFX are not changed.
- `M` creates a named marker at the playhead. Markers can be moved, renamed, removed, and are saved in TagSpaces sidecars as `musicTaggerMarkers`.
- Manual markers are used for XML range export. The current Premiere bridge sends the earliest marker in the selection because it accepts one timestamp.
- Automatic drop/swell detection remains deliberately conservative. Manual markers are the current correction path.

### Maps

- Music/Sound uses the music model layout whenever Music is selected, including when model coverage is low. It does not fall back to SFX labels.
- Search filters only change highlighting. Clear the search to relight the map; switching views is not required.
- **Effects/Tags** is the restored original force/tag layout. A later family-shelf experiment was rejected by the user and removed.
- **Effects/Sound** starts as a basic measured-audio layout. It now includes **Build / update SFX sound map** and **Stop mapping**. The SFX map uses `sfx_map_job.py`, general-audio `laion/clap-htsat-unfused` embeddings, t-SNE, and `model/sfx-soundmap.json`.
- SFX mapping is explicit; it never starts during app launch. It caches vectors in `cache/clap-sfx-v1/`. Completed embeddings survive a cancelled build; the previous map remains until a replacement is ready.
- **Focus matches** fits the camera to highlighted search results. **Show all** restores a full-map framing without rebuilding the layout.
- A small local smoke check found 24/25 WAV crying/whoosh/door files had a nearest neighbour from the same filename-labelled family after SFX embedding and 2D projection. This is evidence the route works, not a full-library quality claim. The user needs to run the map on the real SFX collection and evaluate it.

### SFX workflow

- Filename suggestions take priority. When a filename lacks a specific identity, descriptive relative folder names supply extra hints. Existing tags are not changed until the user chooses to apply suggestions.
- SFX splitting is in the inspector: find silences, review ranges, then create a new sibling folder of WAV clips. The original is retained and sidecar markers are rebased. `ffmpeg`/`ffprobe` are required.

## Key files

| File | Responsibility |
| --- | --- |
| `ui/library_cache.odin` | Snapshot loading/saving and import queue |
| `ui/imports.odin`, `import_folder_job.py` | Safe central-library copy imports |
| `ui/tagging.odin` | Folder rows, selection, reclassification UI |
| `ui/filing.odin`, `mtag/organize.py`, `organize_job.py` | Filing plan and execution |
| `ui/markers.odin` | Editable manual markers |
| `ui/soundmap.odin`, `ui/nodes.odin` | Map rendering and measured fallback |
| `ui/sfx_semantic.odin`, `sfx_map_job.py` | Cached general-audio SFX sound map |
| `ui/sfx.odin` | SFX filename/folder suggestions |
| `ui/split.odin`, `sfx_split_job.py` | Silence-based SFX splitting |
| `tag_job.py`, `ui/tagger.odin` | AI tagging and cached-vector path |

## Known limits and recommended next work

1. Test the real 8,000+ SFX sound-map result before changing the model or map algorithm. The first build is potentially lengthy and may download the CLAP weights on a clean machine.
2. If the SFX map remains weak, capture a small user-reviewed benchmark (for example 30–50 groups such as cries, whooshes, doors, guns) and measure nearest-neighbour quality before replacing the embedding model. Do not tune based on screenshots alone.
3. An installer is not built. The old `MusicTagger.spec` packages the former webview launcher and must not be used as-is. A distributable installer needs a relocatable Python 3.12 runtime, ffmpeg/ffprobe, model setup/download handling, licence notices, per-user writable data, and a clean-machine install/uninstall test. Do not ship personal library paths, preferences, tags, or caches.
4. Premiere integration has not been exercised against the user’s installed version in recent passes. Do not disturb Premiere while it is rendering.
5. SFX drop/swell detection has not been retuned; more labelled examples are needed before changing thresholds.

## Safety notes

- `context.temp_allocator` is cleared every UI frame. Values retained after a frame must be cloned into an owned allocator.
- A rescan replaces `lib.arena`. Clear UI state that holds track pointers or indices before/when replacing the library.
- Caches and maps are keyed by absolute paths. Any new move operation must carry sidecars and re-key embedding/map entries, as existing filing does.
- Never bulk-file or reclassify the real library without the application's plan/confirmation flow.
