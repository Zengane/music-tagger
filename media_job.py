r"""Tag images, video, 3D models and documents, as a child process.

The same shape as tag_job.py and sfx_job.py — newline-delimited JSON on
stdout, one `result` per file, then `done` — so the front end reads all three
the same way.

    venv/bin/python media_job.py --paths-from <file>
    venv/bin/python media_job.py --probe
    venv/bin/python media_job.py --paths-from <file> --no-models   (measured tags only)

A result carries, beyond the audio jobs' fields:

    kind      image, video, model or document
    caption   one or two sentences saying what is in it (Florence-2)
    ocr       text read out of the picture, for memes and titles
    excerpt   the start of a document's text
    thumb     a PNG the front end can show, keyed like its waveform cache
    metrics   what was measured: colours, flashes, cuts, frame rate...

Each model is loaded once for the whole job. A model that cannot be loaded —
not downloaded yet, no network, too little memory — is reported with a
`warning` and the job carries on with what it has: the measured tags still
work with no model at all.
"""

from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from mtag import console  # noqa: E402

CHUNK = 16


def emit(**payload) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def load_models(skip: bool):
    from mtag.media import analyze as AN
    from mtag.media import models as MD

    build = MD.current_build()
    models = AN.Models(build=build.name)
    if skip:
        models.build = ""
        return models, "none"
    dev = "cpu"
    for attr, cls, model_id, label in (
        ("siglip", MD.Siglip, build.siglip, "image model (SigLIP 2)"),
        ("florence", MD.Florence, build.florence, "caption and OCR model (Florence-2)"),
        ("text", MD.TextEmbedder, build.text, "text model (E5)"),
    ):
        emit(event="loading", detail=f"loading the {label}")
        try:
            m = cls(model_id).load()
            setattr(models, attr, m)
            dev = m.dev
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            emit(event="warning", message=f"no {label}: {e}")
    return models, dev


def main() -> int:
    console.init()
    ap = argparse.ArgumentParser()
    ap.add_argument("--paths-from", help="file with one path per line")
    ap.add_argument("--probe", action="store_true", help="load the models and report, analyse nothing")
    ap.add_argument("--no-models", action="store_true", help="measured tags only; load no model")
    ap.add_argument("--no-cache", action="store_true", help="ignore cached results")
    args = ap.parse_args()

    from mtag.audio import have_ffmpeg

    ok_ffmpeg, _ = have_ffmpeg()
    if not ok_ffmpeg:
        emit(event="warning", message=(
            "ffmpeg was not found, so video cannot be read. Put ffmpeg and ffprobe in a 'bin' "
            "folder next to the app, or on your PATH."))

    from mtag.media import analyze as AN
    from mtag.media import models as MD

    models, dev = load_models(args.no_models)
    bank = AN.build_prompts(models)
    emit(event="ready", encoder=f"media-{models.build or 'measured'}", device=dev,
         tags=len(bank.tags), zero_shot=len(bank.tags), build=MD.build_name())

    if args.probe:
        emit(event="done", analyzed=0, failed=0)
        return 0
    if not args.paths_from:
        emit(event="error", message="no work: pass --paths-from or --probe")
        return 2

    paths = list(dict.fromkeys(
        line.strip() for line in Path(args.paths_from).read_text(encoding="utf-8").splitlines() if line.strip()))
    emit(event="total", count=len(paths))

    analysed = failed = 0

    def on_error(path, message):
        nonlocal failed
        failed += 1
        emit(event="error", path=str(path), message=message)

    for start in range(0, len(paths), CHUNK):
        chunk = paths[start:start + CHUNK]  # strings, kept exactly as the app wrote them
        emit(event="loading", detail=f"analysing {start + 1}-{start + len(chunk)} of {len(paths)}")
        try:
            results = AN.analyse_batch(chunk, models, bank, on_error=on_error, use_cache=not args.no_cache)
        except Exception as e:
            # A model failing mid-batch (out of memory, usually) fails the
            # chunk, not the run.
            traceback.print_exc(file=sys.stderr)
            for p in chunk:
                on_error(p, f"analysis failed: {e}")
            continue
        for r in results:
            emit(**r.to_event())
            analysed += 1

    emit(event="done", analyzed=analysed, failed=failed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
