"""Windows console output.

Track filenames in this library contain characters cp1252 can't encode (⧸, ’,
box-drawing substitutes for `/` in ripped titles). Printing one of those to the
default Windows console kills the whole run, so CLI entry points switch stdout
to UTF-8 and degrade unencodable characters instead of raising.
"""

import sys


def init():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
