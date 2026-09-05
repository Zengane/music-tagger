"""Train the final tagger on the library's existing sidecar labels.

    python train.py "H:\\Media Browser\\Mega Music Pack" --encoder muq-mulan

Run this again whenever you've reviewed a batch of new files — their corrected
tags become training data for the next run.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from mtag import console, probes
from mtag.dataset import collect_labelled, embed_all, cli_progress
from mtag.encoders import get_encoder
from mtag.model import Tagger, build_zeroshot, MODEL_PATH
from mtag.taxonomy import ALL_TAGS

console.init()

RESULTS = Path(__file__).resolve().parent / "results"


def train(library: str, encoder_name: str, out=MODEL_PATH, beta: float | None = None) -> Tagger:
    if beta is not None:
        probes.BETA_OVERRIDE = beta
        print(f"threshold bias {beta:.2f} "
              f"({'fewer, surer suggestions' if beta < 1 else 'more suggestions, more wrong ones'})")

    paths, Y = collect_labelled(library)
    print(f"{len(paths)} labelled tracks")

    enc = get_encoder(encoder_name)
    X, kept = embed_all(enc, paths, progress=cli_progress)
    Y = Y[[paths.index(p) for p in kept]]

    print("cross-validating probes...")
    report = probes.evaluate(X, Y)
    s = report["summary"]
    print(
        f"macro AP {s['macro_ap']:.3f}  AUC {s['macro_auc']:.3f}  "
        f"P {s['macro_precision']:.2f}  R {s['macro_recall']:.2f}  "
        f"({s['n_trainable']} trainable tags)"
    )

    models = probes.fit_final(X, Y, report)
    fallback = [t for t in ALL_TAGS if t not in models]
    print(f"zero-shot fallback for {len(fallback)} rare tags: {', '.join(fallback) or '(none)'}")

    zs = build_zeroshot(enc, X, Y, fallback) if fallback else {}
    if fallback and not zs:
        print(f"  note: {encoder_name} has no text tower, those tags stay manual")

    tagger = Tagger(
        encoder_name=encoder_name,
        probes=models,
        zeroshot=zs,
        meta={
            "n_train": int(X.shape[0]),
            "dim": int(X.shape[1]),
            "text_slice": enc.text_slice(X.shape[1]),
            "summary": s,
            "library": str(library),
        },
    )
    tagger.save(out)
    print(f"saved {out}")

    RESULTS.mkdir(exist_ok=True)
    with open(RESULTS / "training_report.json", "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, default=float)

    print(f"\n{'tag':<18}{'n':>5}{'AP':>8}{'prec':>8}{'rec':>8}  source")
    for tag in ALL_TAGS:
        if tag in models:
            m = models[tag]
            print(f"{tag:<18}{m['n_pos']:>5}{m['cv_ap']:>8.3f}"
                  f"{m['cv_precision']:>8.2f}{m['cv_recall']:>8.2f}  probe")
        elif tag in zs:
            print(f"{tag:<18}{zs[tag]['n_pos']:>5}{'-':>8}{'-':>8}{'-':>8}  zero-shot")
        else:
            print(f"{tag:<18}{'?':>5}{'-':>8}{'-':>8}{'-':>8}  manual")
    return tagger


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("library")
    ap.add_argument("--encoder", default="fusion")
    ap.add_argument(
        "--precision", type=float, default=None,
        help="how often a tag has to be right before it applies itself, 0..1. "
             "Run sweep.py to see what each setting costs. Default 0.60.",
    )
    ap.add_argument(
        "--beta", type=float, default=None,
        help="threshold bias: below 1 suggests less and is right more often, "
             "above 1 suggests more and is wrong more often. Default 0.7.",
    )
    args = ap.parse_args()
    if args.precision is not None:
        probes.TARGET_PRECISION = args.precision
        print(f"applying a tag only when it is right {args.precision:.0%} of the time")
    train(args.library, args.encoder, beta=args.beta)


if __name__ == "__main__":
    main()
