r"""Rename ripped tracks from their tags.

    python name_from_tags.py "H:\Media Browser\Mega Music Pack"          # dry run
    python name_from_tags.py "H:\Media Browser\Mega Music Pack" --apply

A soundtrack split from one YouTube video comes out named
`2b5dbd76-92_-_Miitopia.m4a`, with the track name in the "artist" tag. This
renames each file to `092 - A Past Fraught With Sorrow.m4a`. The sidecar
(.ts/*.json) and the analysis caches follow the file, and the soundmap is
re-keyed. Nothing is overwritten.
"""

from __future__ import annotations

import argparse
import collections

from mtag import console, namefix
from mtag.organize import rekey_soundmap

console.init()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("--apply", action="store_true", help="really rename (default is a dry run)")
    args = ap.parse_args()

    entries = namefix.plan(args.folder)
    counts = collections.Counter(e["status"] for e in entries)
    for e in entries:
        if e["status"] == "ok":
            print(f'{e["src"]}\n   -> {e["dst"]}   (from "{e["field"]}")')
    print(f"\n{len(entries)} files: " + ", ".join(f"{n} {s}" for s, n in sorted(counts.items())))

    if not args.apply:
        print("Dry run. Add --apply to rename.")
        return 0

    done = [namefix.apply(e) for e in entries]
    pairs = [(d["src"], d["dst"]) for d in done if d.get("renamed")]
    rekey_soundmap(pairs)
    print(f"Renamed {len(pairs)}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
