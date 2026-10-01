# Model assessment — 2026-10-01

Short version: the music models are good but cannot be sold. The sound
effect side runs on older, weaker models, and the better ones were never
downloaded on this PC. The biggest gain for effects is to train on your own
folders, the same way the music side does.

Not re-checked online today. Licences and candidates come from
`docs/audio-models.md` (2026-09-25) and the code.

## What runs on this PC now

| Job | Model | Notes |
|---|---|---|
| Music tags and music map | MuQ-MuLan + MuQ + CLAP-music, with probes trained on your tags | Works well. MuQ and MuQ-MuLan are **CC-BY-NC**: not for a paid product. |
| Effect categories | AST (AudioSet, 2021) + filename + length | AST scores 45.9 mAP. Older and bigger than the alternatives. |
| Effects map and sound search | General CLAP (2022) | 16.2% neighbour agreement on your effects (the model alone knows 32.7%). |
| PE-AV (newer sound search) | **Not downloaded.** No PE-AV cache exists. | Settings say Auto, so Best (PE-AV large) is chosen, but no effects analysis has run since. |

## Music

1. Quality: fine. The probes trained on your 2,120 tagged tracks are what
   makes it work. Keep them.
2. Licence: to sell the app, MuQ must go. Measure the commercial fusion:
   `bakeoff.py` then `train.py --encoder fusion:clap-music+pe-av-base`
   (`docs/audio-models.md` §4). Within 0.02 average precision of today's
   fusion: switch.
3. Speed: tagging is already model-major (one model on the GPU at a time).
   The map now is too (fixed today).

## Sound effects — why the workflow feels middling

1. **The models are general, the labels are yours.** AST knows 527 AudioSet
   classes ("Door", "Explosion"). Your folders say "Whoosh", "Riser", "UI
   confirm". The mapping in `mtag/sfxtax.py` loses a lot in between.
2. **Nothing learns from you.** On music, your tags train probes. On
   effects, accept/reject changes nothing.
3. **The map uses the weakest model** (general CLAP).

## What I would do, in order

1. **Turn on PE-AV for effects and measure it.** Open the effects map once
   (downloads PE-AV, embeds 6,568 effects on the GPU), then run
   `venv\Scripts\python.exe sfx_map_bench.py pe-av-large` and compare with
   16.2%. Low effort, likely a clear gain for search and the map.
2. **Train effect probes on your folder names**, like the music tagger.
   6,568 effects in named folders is a training set. Probes on PE-AV vectors
   give tags in your words, with measured accuracy. This is the step most
   likely to make effects feel like the music side.
3. **"More like this"** on any effect: nearest neighbours in PE-AV space.
   Cheap once step 1 has run.
4. **Replace AST** with CED-mini (better and ten times smaller) only if its
   licence is cleared (model card says Apache-2.0, the code it runs is
   GPL-3.0). Else EfficientAT (MIT) for the Fast profile.
5. Later: **PE-A-Frame** to find one sound inside a long recording.

## Not recommended

- Qwen2-Audio, Audio Flamingo 3 (they describe sounds in sentences):
  non-commercial licences.
- MERT back in the music fusion: +0.003 for another full pass.
