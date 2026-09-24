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

### Images, video, 3D and documents (added 2026-09-24)

| Model | Licence | Sellable | Used for | Checked |
|---|---|---|---|---|
| [google/siglip2-base-patch16-256](https://huggingface.co/google/siglip2-base-patch16-256) | Apache-2.0 | Yes | small build: image tags, visual search | 2026-09-24 ¹ |
| [google/siglip2-so400m-patch16-384](https://huggingface.co/google/siglip2-so400m-patch16-384) | Apache-2.0 | Yes | large build: same | 2026-09-24 ¹ |
| [florence-community/Florence-2-base](https://huggingface.co/florence-community/Florence-2-base) | MIT | Yes | small build: captions, OCR | 2026-09-24 ¹ |
| [florence-community/Florence-2-large](https://huggingface.co/florence-community/Florence-2-large) | MIT | Yes | large build: same | 2026-09-24 ¹ |
| [intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small) | MIT | Yes | small build: text search, document kinds | 2026-09-24 ¹ |
| [intfloat/multilingual-e5-base](https://huggingface.co/intfloat/multilingual-e5-base) | MIT | Yes | large build: same | 2026-09-24 ¹ |

¹ Hugging Face could not be reached from the environment this was built in.
SigLIP 2 and Florence-2 were confirmed through search results quoting the model
cards; the `florence-community` weights are Microsoft's MIT weights re-uploaded
for the native transformers class; multilingual-e5-small likewise (search
result quoting its card). The large-build variants were not checked
individually. Read all six cards once before a release and replace this
footnote with the date.

The florence-community copies are used rather than `microsoft/Florence-2-*`
because they load through transformers' own `Florence2ForConditionalGeneration`
with no `trust_remote_code`, which is what broke across transformers versions.

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
| Pillow | MIT-CMU (HPND) | Reads images. Fine. |
| pypdfium2, PDFium | Apache-2.0 or BSD-3; PDFium BSD-3 | Renders PDF and PDF-compatible .ai pages. Chosen over Ghostscript (AGPL). |
| python-docx | MIT | Reads .docx. |
| trimesh | MIT | Loads 3D models. Rendering is our own numpy code, no GL library. |
| sentencepiece, protobuf | Apache-2.0, BSD-3 | Tokenizers for SigLIP 2 and E5. |
| resvg-py (optional) | MIT wrapper; resvg MPL-2.0 | SVG. Not installed by default. |
| pillow-heif | BSD-3 wrapper, but bundles LGPL/GPL codecs | **Not used**, for that reason. |
| Blender (optional, external) | GPL | Called as a separate program to convert .fbx/.blend/USD, never bundled. |

## Replacing MuQ

Checked 2026-09-09, after finding MuQ is non-commercial.

| Model | Licence | Sellable | Note |
|---|---|---|---|
| [m-a-p/MERT-v1-330M](https://huggingface.co/m-a-p/MERT-v1-330M) | CC-BY-NC-4.0 | **No** | Already implemented in `encoders.py` and already ruled out for tagging. Ruled out again, for licence. |
| [mispeech/dasheng-base](https://huggingface.co/mispeech/dasheng-base) | **Apache-2.0** | **Yes** | 272,000 hours of speech, music and environmental audio. Strong on HEAR, which includes music tasks. The leading candidate. Also `dasheng-0.6B` and `dasheng-1.2B`. |

**First, though: the music map may not need replacing at all.**

`map_job.py` does not project raw embeddings. It runs each track through the
trained probes and projects the **33 tag scores** — and measured that as better
than raw embeddings (0.66 against 0.75, lower being better).

So the map's quality follows the *probes*, not directly the encoder underneath.
If CLAP-only tagging holds up, the map holds up with it. The encoder question
and the map question are the same question, and it is answered by the retrain
in `roadmap.md` §1, not by finding a MuQ replacement.

The order to try, cheapest first:

1. **CLAP alone.** Already cached, one retrain, no downloads.
2. **CLAP + Dasheng.** A new encoder to add and one full embedding pass, but
   the fusion shape and everything downstream stays as it is.
3. **Something else**, only if both of those measurably lose too much.

Measure the map, not just the tagging. `sfx_map_bench.py` already shows how:
take the user's own tags as families, and ask how often a track's nearest
neighbour on the map shares one.

## Candidates, not yet checked

Verify each before use. Licences on the hub do change between versions.

| Candidate | For | Expected |
|---|---|---|
| SigLIP 2 | images, video, 3D renders | Apache-2.0 — now in use, see above |
| OpenCLIP | same, alternative | MIT (code); weights vary |
| DINOv2 | image similarity without text | Apache-2.0, but check the specific weights |
| BGE / E5 | text embedding | MIT — E5 now in use, see above |
| Qwen 2.5 | local summarising | Apache-2.0 |
| trimesh | 3D loading | MIT — now in use; pyrender not needed |
| Blender headless | `.blend`, `.fbx` | GPL — call it, never bundle it |
