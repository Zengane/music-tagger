"""Rewrite tags that don't exist in the TagSpaces tag library.

    python fix_tags.py "H:\\Media Browser\\Mega Music Pack"          # dry run
    python fix_tags.py "H:\\Media Browser\\Mega Music Pack" --apply

Four names were typed into sidecars that the tag library doesn't contain:

    Jazz                -> Jazzy                 (13 files)
    Bombastic           -> Bombastic-Heavy       (2 files)
    Penny-Big-Breakaway -> Penny's-Big-Breakaway (44 files)
    Jet-Set-Radio       -> Jet-Set-Radio-or-Bomb-Rush-Cyberfunk (1 file)

The first two matter most: they're Mood/Sound tags, so those 15 tracks read as
untagged, never trained the model, and showed up in "untagged only" scans.

Reading already maps these on the fly, so nothing is broken without this — it
just stops TagSpaces from offering two spellings of the same tag.
"""

from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path

from mtag import audio as A, console
from mtag.sidecar import read_sidecar, sidecar_path
from mtag.taxonomy import AUDIO_EXTS, GAME_ALIASES, TAG_ALIASES

console.init()

RENAMES = {**TAG_ALIASES, **GAME_ALIASES}


def scan(root: Path) -> list[tuple[Path, list[tuple[str, str]]]]:
    hits = []
    for f in A.find_audio(root, AUDIO_EXTS, skip_dirs=(), skip_patterns=()):
        titles = [t.get("title") for t in read_sidecar(f).get("tags", [])]
        changes = [(t, RENAMES[t]) for t in titles if t in RENAMES]
        if changes:
            hits.append((f, changes))
    return hits


def rewrite(filepath: Path) -> bool:
    """Rename tags in place, leaving the rest of the sidecar untouched.

    A file that already carries both spellings keeps one, not a duplicate.
    """
    sp = sidecar_path(filepath)
    data = read_sidecar(filepath)
    if not data:
        return False

    seen, out, changed = set(), [], False
    for tag in data.get("tags", []):
        title = tag.get("title")
        new = RENAMES.get(title, title)
        if new != title:
            changed = True
        if new in seen:
            changed = True  # dropping a duplicate spelling
            continue
        seen.add(new)
        out.append({**tag, "title": new})

    if not changed:
        return False
    data["tags"] = out
    with open(sp, "w", encoding="utf-8-sig") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("library")
    ap.add_argument("--apply", action="store_true", help="write the changes")
    args = ap.parse_args()

    root = Path(args.library)
    hits = scan(root)
    if not hits:
        print("Nothing to fix.")
        return

    counts = collections.Counter(c for _, ch in hits for c in ch)
    print(f"{len(hits)} file(s) with tags that aren't in the tag library:\n")
    for (old, new), n in counts.most_common():
        print(f"  {old!r} -> {new!r}   {n} file(s)")
    print()
    for f, ch in hits[:5]:
        print(f"  e.g. {f.relative_to(root)}")

    if not args.apply:
        print("\nDry run. Re-run with --apply to write these changes.")
        return

    done = sum(rewrite(f) for f, _ in hits)
    print(f"\nRewrote {done} sidecar(s).")
    print("Re-run train.py so the newly readable tracks make it into the model.")


if __name__ == "__main__":
    main()
