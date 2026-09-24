#!/usr/bin/env bash
# Builds the native front end on macOS and Linux. The Windows equivalent is
# build.bat. The Python side is not compiled: the jobs are read from source.
set -euo pipefail
cd "$(dirname "$0")"

ODIN="${ODIN:-$(command -v odin || true)}"
if [ -z "$ODIN" ] || [ ! -x "$ODIN" ]; then
    echo "ERROR: Odin not found. Install it from https://odin-lang.org, put odin"
    echo "on your PATH, or set ODIN=/path/to/odin."
    exit 1
fi

# The tag vocabulary lives in mtag/taxonomy.py. Regenerate the front end's copy
# first so the two can never drift apart.
if [ -x venv/bin/python ]; then
    echo "Regenerating the tag vocabulary..."
    venv/bin/python ui/gen_taxonomy.py
else
    echo "No venv yet, using the checked-in ui/taxonomy.odin."
fi

# Replacing a running binary is allowed here (the old one keeps its inode), but
# the running copy stays old until it is restarted.
if pgrep -x MusicTagger >/dev/null 2>&1; then
    echo "Note: Music Tagger is running. Restart it to pick up the new build."
fi

echo "Building MusicTagger..."
"$ODIN" build ui -out:MusicTagger -o:speed

# The same program again, for the self test and the other check modes.
echo "Building mtag-test..."
"$ODIN" build ui -out:mtag-test -o:speed

echo
echo "Ready: $(pwd)/MusicTagger"
echo "Check it with: ./mtag-test --selftest \"<your library folder>\""
