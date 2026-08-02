"""Audio decoding.

ffmpeg does the decoding rather than librosa/audioread: the library is a mix of
mp3, m4a and wav, and ffmpeg handles all of them at the same speed with no
per-format surprises.

The old tagger fed the model a single short slice of the start of each track,
which is why tags were decided by whatever the intro happened to sound like.
Here we spread a fixed number of windows across the whole duration so the
embedding reflects the entire piece.
"""

import subprocess
from pathlib import Path

import numpy as np

from .taxonomy import SKIP_DIRS, SKIP_NAME_PATTERNS

FFMPEG = "ffmpeg"
FFPROBE = "ffprobe"


def duration_seconds(filepath) -> float:
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(filepath)],
        capture_output=True, text=True,
    )
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


def decode(filepath, sr: int, offset: float = 0.0, duration: float | None = None) -> np.ndarray:
    """Decode to mono float32 at `sr`. Returns an empty array on failure."""
    cmd = [FFMPEG, "-v", "error", "-nostdin"]
    if offset:
        cmd += ["-ss", f"{offset:.3f}"]
    cmd += ["-i", str(filepath)]
    if duration is not None:
        cmd += ["-t", f"{duration:.3f}"]
    cmd += ["-f", "f32le", "-acodec", "pcm_f32le", "-ac", "1", "-ar", str(sr), "-"]

    out = subprocess.run(cmd, capture_output=True)
    if out.returncode != 0:
        raise RuntimeError(f"ffmpeg failed on {filepath}: {out.stderr.decode(errors='replace')[:300]}")
    return np.frombuffer(out.stdout, dtype=np.float32)


def windows(filepath, sr: int, window_s: float, max_windows: int) -> np.ndarray:
    """Sample up to `max_windows` fixed-length windows spread across the track.

    Returns shape (n_windows, window_s * sr). Short tracks are zero-padded to a
    single full window.
    """
    total = duration_seconds(filepath)
    win_len = int(window_s * sr)

    if total <= window_s * 1.05:
        audio = decode(filepath, sr)
        if audio.size == 0:
            raise RuntimeError(f"no audio decoded from {filepath}")
        buf = np.zeros(win_len, dtype=np.float32)
        buf[: min(win_len, audio.size)] = audio[:win_len]
        return buf[None, :]

    n = min(max_windows, max(1, int(total // window_s)))
    # Evenly spaced start offsets covering [0, total - window_s].
    span = total - window_s
    starts = [span * i / (n - 1) for i in range(n)] if n > 1 else [0.0]

    audio = decode(filepath, sr)
    out = np.zeros((n, win_len), dtype=np.float32)
    for i, s in enumerate(starts):
        a = int(s * sr)
        chunk = audio[a : a + win_len]
        out[i, : chunk.size] = chunk
    return out


def find_audio(folder, exts, recursive: bool = True,
               skip_dirs=SKIP_DIRS, skip_patterns=SKIP_NAME_PATTERNS) -> list[Path]:
    """Audio files under `folder`, minus the ones this tool has no business tagging.

    Pass `skip_dirs=()` / `skip_patterns=()` to see everything.
    """
    root = Path(folder)
    it = root.rglob("*") if recursive else root.iterdir()
    skip_dirs = {d.lower() for d in skip_dirs}
    out = []
    for p in it:
        if not (p.is_file() and p.suffix.lower() in exts):
            continue
        rel = p.relative_to(root)
        if any(part.lower() in skip_dirs for part in rel.parts[:-1]):
            continue
        name = p.name.lower()
        if any(pat in name for pat in skip_patterns):
            continue
        out.append(p)
    return sorted(out)
