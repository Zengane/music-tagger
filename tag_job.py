r"""One tagging job, run as a child process and then gone.

The Odin front end launches this, streams its output, and lets it exit. There
is no server: nothing Python is resident while you browse the library, so the
encoder cannot be holding VRAM or stalling the window between jobs.

Usage:

    venv\Scripts\python.exe tag_job.py --paths-from <file>

`--paths-from` names a UTF-8 file with one audio path per line, which avoids
the Windows command-line length limit on a batch of several hundred tracks.
Pass `--probe` instead to report the model and device without embedding
anything.

Output is one JSON object per line on stdout — newline-delimited JSON, so the
caller can act on each track as it finishes rather than waiting for the batch:

    {"event": "loading", "detail": "loading encoder fusion"}
    {"event": "ready",   "encoder": "fusion", "device": "cuda", "tags": 33}
    {"event": "result",  "path": "...", "selected": [...], "scores": [...]}
    {"event": "error",   "path": "...", "message": "..."}
    {"event": "done",    "analyzed": 12, "failed": 0}

Anything that is not a complete JSON line is diagnostic noise and the caller
ignores it.
"""

from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from mtag import console, gametag  # noqa: E402


def emit(**payload) -> None:
    """Write one NDJSON line and flush, so the reader sees it immediately."""
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def device_name() -> str:
    try:
        import torch

        return "cuda" if torch.cuda.is_available() else "cpu"
    except Exception:
        return "unknown"


def main() -> int:
    # Filenames in this library contain full-width punctuation and Japanese.
    # Without this the first such path kills the whole run on a cp1252 console.
    console.init()

    ap = argparse.ArgumentParser()
    ap.add_argument("--paths-from", help="file with one audio path per line")
    ap.add_argument("--probe", action="store_true",
                    help="report the model and device, embed nothing")
    args = ap.parse_args()

    from mtag.dataset import EmbeddingCache
    from mtag.encoders import get_encoder
    from mtag.model import MODEL_PATH, Tagger

    if not MODEL_PATH.exists():
        emit(event="error", message=f"No trained model at {MODEL_PATH}. Run train.py first.")
        return 2

    try:
        emit(event="loading", detail="loading tag model")
        tagger = Tagger.load()
        emit(event="loading", detail=f"loading encoder {tagger.encoder_name}")
        encoder = get_encoder(tagger.encoder_name)
        cache = EmbeddingCache(tagger.encoder_name)
    except Exception as e:
        traceback.print_exc(file=sys.stderr)
        emit(event="error", message=f"could not load the model: {e}")
        return 2

    emit(
        event="ready",
        encoder=tagger.encoder_name,
        device=device_name(),
        tags=len(getattr(tagger, "probes", {})),
        zero_shot=len(getattr(tagger, "zeroshot", {})),
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

    # Embed everything first, one model at a time.
    #
    # The loop below asks for a whole fused vector per track, which means every
    # part of the fusion is loaded at once — and three of them do not fit on an
    # 8 GiB card. Windows serves the shortfall out of system RAM rather than
    # failing, at roughly forty times the cost: a 905-file run was measured at
    # just under three minutes a file, about 45 hours.
    #
    # `prefill` does the same work model-major, so only one is ever resident.
    # Afterwards every part is cached and the loop below is pure arithmetic.
    if hasattr(encoder, "prefill"):
        def progress(part, i, n, path, error):
            if n == 0:
                emit(event="loading", detail=f"{part}: already done")
            elif i == 1 or i == n or i % 10 == 0:
                emit(event="loading", detail=f"embedding with {part}: {i} of {n}")
            if error:
                emit(event="error", path=str(path), message=f"{part}: {error}")

        try:
            encoder.prefill(paths, progress)
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            emit(event="error", message=f"embedding failed: {e}")
            return 2
        # Back to Running: the progress above is reported as Loading, and the
        # per-track results that follow belong to the running phase.
        emit(
            event="ready",
            encoder=tagger.encoder_name,
            device=device_name(),
            tags=len(getattr(tagger, "probes", {})),
            zero_shot=len(getattr(tagger, "zeroshot", {})),
        )

    analyzed = failed = 0
    for raw in paths:
        path = Path(raw)
        try:
            vector = cache.get(path)
            if vector is None:
                vector = encoder.embed_file(path)
                cache.put(path, vector)
            result = tagger.suggest(vector)

            # Flatten the per-tag dict into a list so the reader does not have
            # to walk an object of unknown keys.
            scores = [
                {
                    "tag": tag,
                    "score": round(float(info["score"]), 4),
                    "threshold": round(float(info["threshold"]), 4),
                    "zero_shot": info.get("source") == "zeroshot",
                }
                for tag, info in result["scores"].items()
            ]
            emit(
                event="result",
                path=str(path),
                selected=result["selected"],
                scores=scores,
                game=gametag.detect(path) or "",
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
