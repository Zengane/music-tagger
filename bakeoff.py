"""Score every candidate encoder against the user's own labels.

    python bakeoff.py "H:\\Media Browser\\Mega Music Pack"

Embeddings are cached per encoder, so re-running is cheap and adding a new
encoder only costs that encoder's pass.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from mtag import console, probes
from mtag.dataset import collect_labelled, embed_all, cli_progress
from mtag.encoders import ENCODERS, get_encoder
from mtag.taxonomy import ALL_TAGS

console.init()

RESULTS = Path(__file__).resolve().parent / "results"


def run(library: str, encoder_names: list[str]) -> dict:
    paths, Y = collect_labelled(library)
    print(f"{len(paths)} labelled tracks, {Y.sum()} tag assignments\n")

    all_reports = {}
    for name in encoder_names:
        print(f"=== {name} ===")
        t0 = time.time()
        enc = get_encoder(name)
        X, kept = embed_all(enc, paths, progress=cli_progress)

        keep_idx = [paths.index(p) for p in kept]
        Yk = Y[keep_idx]
        print(f"embedded {X.shape[0]} tracks, dim {X.shape[1]}, {time.time() - t0:.0f}s")

        report = probes.evaluate(X, Yk)
        s = report["summary"]
        print(
            f"macro AP {s['macro_ap']:.3f} | macro AUC {s['macro_auc']:.3f} | "
            f"lift x{s['macro_lift']:.1f} | P {s['macro_precision']:.2f} "
            f"R {s['macro_recall']:.2f} over {s['n_trainable']} tags\n"
        )
        all_reports[name] = report

        del enc
        import torch, gc
        gc.collect()
        if torch.cuda.is_available():
            torch.cuda.empty_cache()

    return all_reports


def print_table(all_reports: dict) -> None:
    names = list(all_reports)
    print("\n" + "=" * (24 + 10 * len(names)))
    print("Per-tag average precision (higher is better)")
    print("=" * (24 + 10 * len(names)))
    header = f"{'tag':<18}{'n':>4}  " + "".join(f"{n:>12}" for n in names)
    print(header)
    for tag in ALL_TAGS:
        rows = {n: next(r for r in all_reports[n]["per_tag"] if r["tag"] == tag) for n in names}
        any_row = rows[names[0]]
        if "ap" not in any_row:
            continue
        mark = "" if any_row["trainable"] else " *"
        best = max(rows[n]["ap"] for n in names)
        cells = ""
        for n in names:
            v = rows[n]["ap"]
            cells += f"{v:>11.3f}" + ("*" if v == best else " ")
        print(f"{tag + mark:<18}{any_row['n_pos']:>4}  {cells}")

    print("-" * (24 + 10 * len(names)))
    for key, label in (("macro_ap", "MACRO AP"), ("macro_auc", "MACRO AUC"),
                       ("macro_lift", "LIFT vs base"), ("macro_recall", "RECALL @thr"),
                       ("macro_precision", "PRECISION @thr")):
        cells = "".join(f"{all_reports[n]['summary'][key]:>12.3f}" for n in names)
        print(f"{label:<24}{cells}")
    print("\n* = fewer than %d positives, routed to zero-shot fallback" % probes.MIN_POSITIVES)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("library")
    # The music candidates. The general-audio CLAP is for effects and is left
    # out; name it explicitly to include it.
    ap.add_argument("--encoders", nargs="+",
                    default=["muq-mulan", "muq", "mert", "clap-music", "pe-av-small", "pe-av-base"])
    args = ap.parse_args()

    reports = run(args.library, args.encoders)
    print_table(reports)

    RESULTS.mkdir(exist_ok=True)
    out = RESULTS / "bakeoff.json"
    with open(out, "w", encoding="utf-8") as f:
        json.dump(reports, f, indent=2, default=float)
    print(f"\nwrote {out}")

    winner = max(reports, key=lambda n: reports[n]["summary"]["macro_ap"])
    print(f"winner: {winner}")


if __name__ == "__main__":
    main()
