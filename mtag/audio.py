"""Audio decoding.

ffmpeg does the decoding rather than librosa/audioread: the library is a mix of
mp3, m4a and wav, and ffmpeg handles all of them at the same speed with no
per-format surprises.

The old tagger fed the model a single short slice of the start of each track,
which is why tags were decided by whatever the intro happened to sound like.
Here we spread a fixed number of windows across the whole duration so the
embedding reflects the entire piece.
"""

import os
import subprocess
from pathlib import Path

import numpy as np

from .taxonomy import SKIP_DIRS, SKIP_NAME_PATTERNS

def _tool(name: str) -> str:
    """Where to find ffmpeg, in the order most likely to be right.

    Everything here decodes through ffmpeg — every format, including plain WAV
    and MP3 — so without it nothing can be analysed at all. A user who skipped
    it because they "only work with wav and mp3" got a tagging run that
    reported a failure per file and applied nothing, which reads as the AI
    being broken rather than as a missing program.

    `bin/` beside the application is checked first so the answer to "what path
    do I put it on?" can be "drop the two .exe files in this folder", which
    needs no environment variables and no administrator.
    """
    import shutil

    exe = f"{name}.exe" if os.name == "nt" else name

    override = os.environ.get(f"MUSICTAGGER_{name.upper()}")
    if override and Path(override).exists():
        return override

    here = Path(__file__).resolve().parent.parent
    for candidate in (here / "bin" / exe, here / exe):
        if candidate.exists():
            return str(candidate)

    return shutil.which(name) or name


FFMPEG = _tool("ffmpeg")
FFPROBE = _tool("ffprobe")


def have_ffmpeg() -> tuple[bool, str]:
    """Whether decoding will work at all, and where it would come from."""
    import shutil

    found = Path(FFMPEG).exists() or shutil.which(FFMPEG) is not None
    return found, FFMPEG


def _run_process(command, **kwargs):
    """Run a decoder without flashing a console in the Windows desktop app."""
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    return subprocess.run(command, **kwargs)


def duration_seconds(filepath) -> float:
    out = _run_process(
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

    out = _run_process(cmd, capture_output=True)
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


def waveform(filepath, points: int = 1200) -> dict:
    """Return a compact peak envelope suitable for drawing a timeline.

    This is intentionally separate from model embedding: the UI can request a
    fast, low-resolution preview without loading an encoder or changing the
    tagger's training data.
    """
    points = max(64, min(int(points), 4000))
    duration = duration_seconds(filepath)
    if duration <= 0:
        return {"duration": 0.0, "peaks": []}

    # A modest sample rate keeps preview generation cheap while retaining the
    # transient shape editors need to identify hits and transitions.
    sr = 8000
    samples = decode(filepath, sr)
    if samples.size == 0:
        return {"duration": duration, "peaks": []}

    count = min(points, samples.size)
    peaks = np.zeros(count, dtype=np.float32)
    edges = np.linspace(0, samples.size, count + 1, dtype=np.int64)
    absolute = np.abs(samples)
    for i in range(count):
        start, end = int(edges[i]), int(edges[i + 1])
        if end > start:
            peaks[i] = float(absolute[start:end].max())
    scale = float(np.quantile(peaks, 0.995)) if np.any(peaks) else 1.0
    if scale <= 0:
        scale = 1.0
    return {"duration": duration, "peaks": np.clip(peaks / scale, 0, 1).round(4).tolist()}


def export_clip(filepath, start: float, end: float, destination) -> None:
    """Render a universally importable WAV excerpt for external-editor drag-out."""
    length = max(0.05, end - start)
    cmd = [FFMPEG, "-v", "error", "-nostdin", "-y", "-ss", f"{start:.3f}",
           "-i", str(filepath), "-t", f"{length:.3f}", "-vn", "-acodec", "pcm_s16le",
           str(destination)]
    out = _run_process(cmd, capture_output=True)
    if out.returncode != 0:
        raise RuntimeError(f"ffmpeg could not render selection: {out.stderr.decode(errors='replace')[:300]}")


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
