"""Console output, and behaving well as a background job.

Track filenames in this library contain characters cp1252 can't encode (⧸, ’,
box-drawing substitutes for `/` in ripped titles). Printing one of those to the
default Windows console kills the whole run, so CLI entry points switch stdout
to UTF-8 and degrade unencodable characters instead of raising.

When the app starts a job it sets MUSICTAGGER_BACKGROUND=1, and the job then
steps out of the way of whatever else the computer is doing:

  - its priority drops below normal, so the desktop, the app and whatever
    you are editing in are served first. Programs it starts (ffmpeg) inherit
    that.
  - the maths libraries get half the cores instead of all of them. numpy,
    torch and numba each default to every core, and a music analysis that
    feeds a GPU does not need them: the extra threads only fight the rest of
    the machine. Measured runs from the command line (train.py, bakeoff.py)
    do not set the variable and keep full speed.
"""

import os
import sys


def thread_budget() -> int:
    """Threads a background job may use: half the logical cores, 2 to 8."""
    return max(2, min(8, (os.cpu_count() or 4) // 2))


def background() -> bool:
    return os.environ.get("MUSICTAGGER_BACKGROUND") == "1"


def _lower_priority() -> None:
    try:
        if os.name == "nt":
            import ctypes

            BELOW_NORMAL_PRIORITY_CLASS = 0x00004000
            kernel32 = ctypes.windll.kernel32
            kernel32.SetPriorityClass(kernel32.GetCurrentProcess(), BELOW_NORMAL_PRIORITY_CLASS)
        else:
            os.nice(10)
    except Exception:
        pass


def calm_torch() -> None:
    """Called once torch is imported; the environment variables below only
    reach it when set before that."""
    if not background():
        return
    try:
        import torch

        torch.set_num_threads(thread_budget())
    except Exception:
        pass


def init():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    if background():
        _lower_priority()
        n = str(thread_budget())
        for var in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS",
                    "NUMEXPR_NUM_THREADS", "NUMBA_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
            os.environ.setdefault(var, n)
        if "torch" in sys.modules:
            calm_torch()
