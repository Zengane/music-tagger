"""Prints the current commit, short, for build.bat and build.sh.

Read straight out of the .git folder, so it works where git itself is not on
PATH (GitHub Desktop installs keep it to themselves). Prints "unknown" when
there is nothing to read.
"""

from pathlib import Path

root = Path(__file__).resolve().parent.parent
git = root / ".git"


def commit() -> str:
    head = (git / "HEAD").read_text(encoding="utf-8").strip()
    if not head.startswith("ref: "):
        return head
    ref = head[5:].strip()
    loose = git / ref
    if loose.exists():
        return loose.read_text(encoding="utf-8").strip()
    packed = git / "packed-refs"
    if packed.exists():
        for line in packed.read_text(encoding="utf-8").splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[1] == ref:
                return parts[0]
    return "unknown"


try:
    sha = commit()
except OSError:
    sha = "unknown"
print(sha[:7] if sha != "unknown" else sha)
