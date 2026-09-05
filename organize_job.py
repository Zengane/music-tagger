r"""One filing job: move tagged tracks into the folder named after their mood.

The library is laid out by mood — `Adventure/`, `Chill/`, `Tension/` — and a
newly tagged track is supposed to end up in the one it was tagged with. The old
web front end did this; the native one never learned to, so tracks stayed in
`Untagged/` wearing the right tags. This is that step, as a job the front end
can run the same way it runs tagging.

Usage:

    venv\Scripts\python.exe organize_job.py --plan  --moves-from <file>
    venv\Scripts\python.exe organize_job.py --apply --moves-from <file>

The file holds one move per line, mood and path separated by a tab:

    Chill\tH:\Media Browser\Mega Music Pack\Untagged\Foo.mp3

Two phases on purpose. `--plan` touches nothing and reports what each move
would do, so the caller can show it and ask; `--apply` carries them out. Moving
several hundred files is not something to find out about afterwards.

Output is newline-delimited JSON, as with the tagging job:

    {"event": "total",  "count": 792}
    {"event": "plan",   "src": "...", "dst": "...", "folder": "Chill", "status": "ok"}
    {"event": "moved",  "src": "...", "dst": "...", "folder": "Chill"}
    {"event": "error",  "path": "...", "message": "..."}
    {"event": "done",   "moved": 792, "skipped": 0, "failed": 0}

`status` is one of ok, already-there, collision, missing. Nothing is ever
overwritten: a move that would land on an existing file is reported as a
collision and skipped.
"""

from __future__ import annotations

import argparse
import json
import sys
import traceback
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from mtag import console, organize  # noqa: E402


def emit(**payload) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def read_moves(path: Path) -> list[tuple[str, str]]:
    """Lines of `mood<TAB>path`. Blank lines and malformed ones are dropped."""
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        mood, _, filepath = line.partition("\t")
        mood, filepath = mood.strip(), filepath.strip()
        if mood and filepath:
            out.append((mood, filepath))
    return out


def main() -> int:
    # Same reason as the tagging job: these filenames are full of Japanese and
    # full-width punctuation, and a cp1252 console kills the run on the first.
    console.init()

    ap = argparse.ArgumentParser()
    ap.add_argument("--moves-from", required=True,
                    help="file with one `mood<TAB>path` per line")
    ap.add_argument("--library", default="", help="library root; inferred if omitted")
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--plan", action="store_true", help="report only, move nothing")
    group.add_argument("--apply", action="store_true", help="carry the moves out")
    args = ap.parse_args()

    try:
        moves = read_moves(Path(args.moves_from))
    except OSError as e:
        emit(event="error", message=f"could not read the move list: {e}")
        return 2

    emit(event="total", count=len(moves))
    if not moves:
        emit(event="done", moved=0, skipped=0, failed=0)
        return 0

    # The library root is the folder the mood folders live in. The caller knows
    # it; falling back to the first path's top level is for running this by hand.
    library = Path(args.library) if args.library else Path(moves[0][1]).parents[-2]

    counts: Counter[str] = Counter()
    moved = failed = 0
    carried: list[tuple[str, str]] = []  # (src, dst) of everything that moved

    for mood, filepath in moves:
        try:
            entry = organize.plan(filepath, library, mood)
        except ValueError as e:  # not a Mood tag
            emit(event="error", path=filepath, message=str(e))
            failed += 1
            continue
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            emit(event="error", path=filepath, message=str(e))
            failed += 1
            continue

        counts[entry["status"]] += 1

        if args.plan:
            emit(event="plan", src=entry["src"], dst=entry["dst"],
                 folder=entry["folder"], mood=entry["mood"], status=entry["status"])
            continue

        if entry["status"] != "ok":
            continue

        try:
            done = organize.apply(entry)
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            emit(event="error", path=filepath, message=str(e))
            failed += 1
            continue

        if done.get("moved"):
            moved += 1
            carried.append((done["src"], done["dst"]))
            emit(event="moved", src=done["src"], dst=done["dst"],
                 folder=done["folder"], mood=done["mood"])
        else:
            # Lost a race, or turned into a collision between plan and apply.
            emit(event="error", path=filepath,
                 message=f"not moved: {done.get('status', 'unknown')}")
            failed += 1

    # The map remembers each track by path too, and it is one document — so it is
    # re-keyed once, here, rather than on every move.
    remapped = organize.rekey_soundmap(carried) if carried else 0
    if remapped:
        emit(event="remapped", count=remapped)

    skipped = sum(n for status, n in counts.items() if status != "ok")
    emit(event="done", moved=moved, skipped=skipped, failed=failed,
         remapped=remapped, statuses=dict(counts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
