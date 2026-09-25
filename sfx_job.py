r"""Tag sound effects, as a child process that exits when it is done.

Same shape as tag_job.py — newline-delimited JSON on stdout, one line per
file — but a different model and a different vocabulary.

    venv\Scripts\python.exe sfx_job.py --paths-from <file>
    venv\Scripts\python.exe sfx_job.py --probe

Three sources of tags, in decreasing order of how much they can be trusted:

  1. **The filename.** For game audio it usually says outright what the sound
     is for: "ui_confirm_01.wav". This needs no model and is right far more
     often than anything acoustic would be, because it is the designer's own
     word for it.

  2. **Length.** One-Shot, Loop and Tail are measurable — a loop's start and
     end match, a one-shot decays to nothing — so they are measured rather
     than guessed.

  3. **An AudioSet tagger.** AudioSet is a sound-effect ontology, so an
     off-the-shelf model already emits classes like Door, Footsteps, Glass and
     Explosion. Its 527 classes are folded into our vocabulary by
     mtag/sfxtax.py.

What it deliberately does not do is guess *intent*. Confirm and Cancel are the
same sound acoustically and differ only in what the designer meant by them, so
they come from the filename or from the editor, never from the model.
"""

from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from mtag import console, sfxtax  # noqa: E402

# Off-the-shelf, trained on AudioSet, and small enough to be practical.
MODEL_ID = "MIT/ast-finetuned-audioset-10-10-0.4593"

# Below this an AudioSet class is noise. Chosen low because the mapping already
# throws most classes away, and a missing tag is worse than one to reject.
SCORE_FLOOR = 0.10
TOP_K = 12

# Zero-shot scores from the sound search model are scaled down so that, until
# they have been measured on a real library, they only reach the applying
# threshold (0.35) when the model is very sure.
ZS_WEIGHT = 0.5


def emit(**payload) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def device_name() -> str:
    try:
        import torch

        return "cuda" if torch.cuda.is_available() else "cpu"
    except Exception:
        return "unknown"


def measure_length(samples, sr: int) -> tuple[list[str], float]:
    """One-Shot, Loop or Tail, from the audio itself.

    A loop is made to be butt-joined, so its first and last moments are at a
    similar level. A one-shot decays to silence. Anything long that does
    neither is left alone rather than mislabelled.

    Takes the samples the tagger already decoded: this used to decode every
    file a second time at 8 kHz just to measure it.
    """
    if samples is None or samples.size == 0:
        return [], 0.0

    import numpy as np

    duration = samples.size / sr
    window = max(int(0.05 * sr), 1)
    head = float(np.abs(samples[:window]).mean())
    tail = float(np.abs(samples[-window:]).mean())
    peak = float(np.abs(samples).max()) or 1.0

    tags: list[str] = []
    if tail < peak * 0.02:
        # Ends in silence: it stops on its own.
        tags.append("One-Shot")
        if duration > 1.5:
            tags.append("Tail")
    elif duration > 1.0 and head > peak * 0.05 and tail > peak * 0.05:
        # Starts and ends alive at similar levels: made to be repeated.
        if 0.5 < (tail / max(head, 1e-6)) < 2.0:
            tags.append("Loop")
    return tags, duration


def main() -> int:
    console.init()

    ap = argparse.ArgumentParser()
    ap.add_argument("--paths-from", help="file with one audio path per line")
    ap.add_argument("--probe", action="store_true",
                    help="report the model and device, tag nothing")
    ap.add_argument("--no-model", action="store_true",
                    help="filename and length only; do not load the tagger")
    args = ap.parse_args()

    model = None
    extractor = None
    labels: dict[int, str] = {}

    if not args.no_model:
        try:
            emit(event="loading", detail="loading the AudioSet tagger")
            import torch
            from transformers import ASTForAudioClassification, AutoFeatureExtractor

            extractor = AutoFeatureExtractor.from_pretrained(MODEL_ID)
            model = ASTForAudioClassification.from_pretrained(MODEL_ID)
            model.eval()
            if torch.cuda.is_available():
                model = model.to("cuda")
            labels = model.config.id2label
        except Exception as e:
            # Not fatal: the filename and the length still work, and saying so
            # is better than failing the whole run.
            traceback.print_exc(file=sys.stderr)
            emit(event="warning",
                 message=f"no AudioSet model ({e}); using filenames and length only")
            model = None

    # The profile's sound-and-text model (mtag/profiles.py). With PE-AV it
    # also answers "is this a riser? metal? outdoors?" directly, in the
    # effects' own words; with either it stores a vector per file, which is
    # what search by description and the effects map read.
    zs = None
    zs_tags: list[str] = []
    zs_text = None
    if not args.no_model:
        try:
            from mtag.dataset import EmbeddingCache
            from mtag.encoders import audio_text_encoder

            zs = audio_text_encoder()
            emit(event="loading", detail=f"loading the sound search model ({zs.MODEL_ID})")
            zs.load()
            zs_cache = EmbeddingCache(zs.name)
            if hasattr(zs, "probabilities"):
                phrases, owner = [], []
                for tag, ps in sfxtax.SFX_PROMPTS.items():
                    for ph in ps:
                        phrases.append(ph)
                        owner.append(tag)
                zs_tags = owner
                zs_text = zs.embed_text(phrases, raw=True)
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            emit(event="warning", message=f"no sound search model ({e}); tags still work, search by description of effects will not")
            zs = None

    emit(
        event="ready",
        encoder="audioset" if model is not None else "filename+length",
        device=device_name() if model is not None else "cpu",
        tags=len(sfxtax.ALL_SFX_TAGS),
        zero_shot=0,
    )

    if args.probe:
        emit(event="done", analyzed=0, failed=0)
        return 0

    if not args.paths_from:
        emit(event="error", message="no work: pass --paths-from or --probe")
        return 2

    paths = [
        line.strip()
        for line in Path(args.paths_from).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    emit(event="total", count=len(paths))

    analyzed = failed = 0
    for raw in paths:
        path = Path(raw)
        try:
            scores: dict[str, float] = {}

            from mtag import audio as A

            # One decode, at the rate the AudioSet model wants, serves both it
            # and the length measurement.
            try:
                wave16 = A.decode(path, sr=16000)
            except Exception:
                wave16 = None
            length_tags, duration = measure_length(wave16, 16000)
            for tag in length_tags:
                scores[tag] = max(scores.get(tag, 0.0), 0.9)

            if model is not None and wave16 is not None:
                import numpy as np
                import torch

                # The model wants 16 kHz mono. Effects are short, so the whole
                # file goes in; anything longer than ten seconds is trimmed,
                # which is where the useful part of a long ambience is anyway.
                wave = wave16
                if wave.size:
                    wave = wave[: 16000 * 10]
                    inputs = extractor(wave, sampling_rate=16000, return_tensors="pt")
                    if next(model.parameters()).is_cuda:
                        inputs = {k: v.to("cuda") for k, v in inputs.items()}
                    with torch.no_grad():
                        logits = model(**inputs).logits[0]
                    probs = torch.sigmoid(logits).cpu().numpy()

                    top = np.argsort(probs)[::-1][:TOP_K]
                    scored = [
                        (labels[int(i)], float(probs[int(i)]))
                        for i in top
                        if float(probs[int(i)]) >= SCORE_FLOOR
                    ]
                    for tag, score in sfxtax.tags_for_labels(scored).items():
                        scores[tag] = max(scores.get(tag, 0.0), score)

            zs_scores: dict[str, float] = {}
            if zs is not None:
                import numpy as np

                cached = zs_cache.get(path) if zs_text is None else None
                if cached is None:
                    windows = zs.embed_windows_file(path)
                    from mtag.encoders import _pool

                    zs_cache.put(path, _pool(windows))
                    if zs_text is not None and len(windows):
                        probs = zs.probabilities(windows.mean(axis=0, keepdims=True), zs_text)[0]
                        for tag, p in zip(zs_tags, probs):
                            zs_scores[tag] = max(zs_scores.get(tag, 0.0), float(p))
                for tag, p in zs_scores.items():
                    # Suggested, not applied, until measured: the threshold
                    # below is a starting point (docs/audio-models.md).
                    scores.setdefault(tag, 0.0)
                    scores[tag] = max(scores[tag], p * ZS_WEIGHT)

            ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
            emit(
                event="result",
                path=str(path),
                selected=[tag for tag, score in ranked if score >= 0.35],
                scores=[
                    {
                        "tag": tag,
                        "score": round(score, 4),
                        "threshold": 0.35,
                        # Marked in the inspector: a guess from a text
                        # prompt, not from a trained classifier.
                        "zero_shot": tag in zs_scores and score <= zs_scores[tag] * ZS_WEIGHT + 1e-9,
                    }
                    for tag, score in ranked
                ],
                game="",
                duration=round(duration, 2),
            )
            analyzed += 1
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            emit(event="error", path=str(path), message=str(e))
            failed += 1

    emit(event="done", analyzed=analyzed, failed=failed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
