r"""How many tags you get, and how many of them are wrong, at each setting.

    venv\Scripts\python.exe sweep.py "H:\Media Browser\Mega Music Pack"

The tagger has one dial that matters — how sure it has to be before it applies a
tag — and every complaint about it so far has been about where that dial sits.
"Too many wrong ones" and "too harsh, only one or two tags" are the same dial at
two settings, so the way to settle it is to see the whole range at once rather
than to keep nudging.

The numbers are per track, cross-validated on your own labels:

    found    tags it applies that you would have applied too
    wrong    tags it applies that you would not have
    missed   tags you use that it stays quiet about

Out-of-fold scores are computed once and then every setting is measured against
the same scores, so the comparison is exact and the whole sweep costs one
training run.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from mtag import console, probes  # noqa: E402
from mtag.dataset import collect_labelled, embed_all, cli_progress  # noqa: E402
from mtag.encoders import get_encoder  # noqa: E402
from mtag.taxonomy import ALL_TAGS  # noqa: E402

console.init()


def measure(y, oof, target, min_recall=probes.MIN_RECALL):
    """(applied, right, wrong) per track for one tag at one precision target."""
    thr, prec, rec, reached = probes.threshold_for_precision(y, oof, target)
    if not reached:
        return 0.0, 0.0, 0.0, False
    prevalence = y.mean()
    right = prevalence * rec
    wrong = right * (1 / prec - 1) if prec > 0 else 0.0
    return right + wrong, right, wrong, True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("library")
    ap.add_argument("--encoder", default="fusion")
    args = ap.parse_args()

    paths, Y = collect_labelled(args.library)
    print(f"{len(paths)} labelled tracks")

    enc = get_encoder(args.encoder)
    X, kept = embed_all(enc, paths, progress=cli_progress)
    Y = Y[[paths.index(p) for p in kept]]

    per_track = Y.sum(axis=1).mean()
    print(f"you tag {per_track:.1f} of these per track on average\n")

    print("cross-validating once...")
    oofs = {}
    for i, tag in enumerate(ALL_TAGS):
        y = Y[:, i].astype(int)
        if int(y.sum()) < probes.MIN_POSITIVES:
            continue
        oofs[tag] = (y, probes.out_of_fold_scores(X, y)[0])
    print(f"{len(oofs)} tags have enough examples to learn from\n")

    print(f"{'sure enough at':>15}  {'tags/track':>10} {'right':>7} {'wrong':>7} "
          f"{'missed':>7}  {'applied by':>10}")
    for target in (0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80):
        applied = right = wrong = 0.0
        auto = 0
        for tag, (y, oof) in oofs.items():
            a, r, w, reached = measure(y, oof, target)
            applied += a
            right += r
            wrong += w
            auto += 1 if reached else 0
        missed = per_track - right
        print(f"{target:>15.2f}  {applied:>10.1f} {right:>7.1f} {wrong:>7.1f} "
              f"{missed:>7.1f}  {auto:>10d}")

    print("\nEverything a tag is not sure enough to apply is still scored and")
    print("still offered in the inspector, one click to accept.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
