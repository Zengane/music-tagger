# Model licences

Every model this app downloads or depends on, and whether it may be used in
something sold. Checked against the model card on the date shown.

**Add a row before wiring a model in, not after.** Finding out that a licence
forbids selling once the UI is built around the model is the expensive order to
do this in.

Acceptable for a paid product: MIT, BSD, Apache-2.0, CC-BY-4.0.
Not acceptable: CC-BY-**NC**, "research only", "non-commercial", or any custom
licence with a use restriction. Read Llama-family licences rather than assuming;
they are not OSI-approved and carry conditions.

## In use now

| Model | Licence | Sellable | Used for | Checked |
|---|---|---|---|---|
| [OpenMuQ/MuQ-large-msd-iter](https://huggingface.co/OpenMuQ/MuQ-large-msd-iter) | CC-BY-NC-4.0 | **No** | music fusion, 1 of 3 | 2026-09-09 |
| [OpenMuQ/MuQ-MuLan-large](https://huggingface.co/OpenMuQ/MuQ-MuLan-large) | CC-BY-NC-4.0 | **No** | music fusion + zero-shot text | 2026-09-09 |
| [laion/larger_clap_music_and_speech](https://huggingface.co/laion/larger_clap_music_and_speech) | Apache-2.0 | Yes | music fusion, 1 of 3 | 2026-09-09 |
| [laion/clap-htsat-unfused](https://huggingface.co/laion/clap-htsat-unfused) | Apache-2.0 | Yes | the effects map | 2026-09-09 |
| [MIT/ast-finetuned-audioset-10-10-0.4593](https://huggingface.co/MIT/ast-finetuned-audioset-10-10-0.4593) | BSD-3-Clause | Yes | effects tagging | 2026-09-09 |
| [xlm-roberta-base](https://huggingface.co/xlm-roberta-base) | MIT | Yes | pulled in by MuQ-MuLan's text tower | not yet verified |

**The consequence:** the music tagger as trained cannot be sold. It runs on a
vector built from all three encoders, two of which are non-commercial. See
`roadmap.md` §1 — the fix is to retrain on CLAP alone and measure what that
costs.

The effects side is already clean.

## Not models, but shipped or called

| Thing | Licence | Notes |
|---|---|---|
| ffmpeg / ffprobe | LGPL or GPL depending on build | Not bundled. `setup.bat` downloads a third-party build, and the app calls it as an external program. Keep it that way. |
| Adobe `CSInterface.js` | BSD | Shipped inside the Zen Drop panel. |
| Odin, raylib | BSD-like / zlib | Fine. |
| torch, transformers, numpy, scikit-learn, umap-learn | BSD / Apache-2.0 / MIT | Fine. |

## Candidates, not yet checked

Verify each before use. Licences on the hub do change between versions.

| Candidate | For | Expected |
|---|---|---|
| SigLIP 2 | images, video, 3D renders | Apache-2.0 |
| OpenCLIP | same, alternative | MIT |
| DINOv2 | image similarity without text | Apache-2.0, but check the specific weights |
| BGE / E5 | text embedding | MIT |
| Qwen 2.5 | local summarising | Apache-2.0 |
| trimesh, pyrender | 3D loading and offscreen rendering | MIT |
| Blender headless | `.blend`, `.fbx` | GPL — call it, never bundle it |
