"""Turning any visual file into pictures, and any document into text.

Every analysis downstream works on a few RGBA frames at a modest size, so this
module is where format knowledge lives. Nothing here needs a model.

    image     one frame, alpha kept
    video     up to N frames spread across the clip, alpha kept when the codec
              carries it, plus the per-frame brightness curve at a higher rate
    3D model  turntable views from mtag/media/render3d.py
    document  the first page rendered (PDF) and the text

ffmpeg is the fallback reader for anything Pillow cannot open, and the only
reader for video. It is already required for audio.
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .. import audio as A
from .. import kinds as K

# Frames are analysed at this long edge. Large enough for OCR on a meme and for
# SigLIP at 384, small enough that sixteen of them are a few MB.
FRAME_EDGE = 768


@dataclass
class Probe:
    """What ffprobe says about a video (or an animated image)."""

    duration: float = 0.0
    width: int = 0
    height: int = 0
    fps: float = 0.0
    codec: str = ""
    pix_fmt: str = ""
    has_alpha: bool = False
    has_audio: bool = False
    hdr: bool = False
    frames: int = 0


@dataclass
class Visual:
    """Frames of one file, ready to look at."""

    frames: list[np.ndarray] = field(default_factory=list)  # HxWx4 uint8, RGBA
    times: list[float] = field(default_factory=list)        # seconds, video only
    probe: Probe | None = None
    # The whole video at 32x18 grey, about 12 frames a second. The flash,
    # fade, cut and motion measurements read this; it is far cheaper than
    # decoding full frames at that rate.
    tiny: np.ndarray | None = None
    tiny_rate: float = 0.0
    source_alpha: bool = False  # the file itself carries transparency
    extra: dict = field(default_factory=dict)


def _run(cmd: list[str], **kw):
    return A._run_process(cmd, capture_output=True, **kw)


# ── images ──────────────────────────────────────────────────────────────────

def _fit(img, edge: int = FRAME_EDGE):
    """Shrink so the long side is at most `edge`. Never enlarges."""
    w, h = img.size
    scale = edge / max(w, h)
    if scale < 1:
        img = img.resize((max(1, round(w * scale)), max(1, round(h * scale))), resample=3)
    return img


def _pil_to_rgba(img) -> tuple[np.ndarray, bool]:
    """RGBA array, and whether the source genuinely had an alpha channel."""
    had_alpha = img.mode in ("RGBA", "LA", "PA") or (img.mode == "P" and "transparency" in img.info)
    if img.mode != "RGBA":
        img = img.convert("RGBA")
    return np.asarray(img, dtype=np.uint8).copy(), had_alpha


def load_image(path: Path) -> Visual:
    """One RGBA frame. Vector and layered formats are rasterised first."""
    ext = path.suffix.lower()
    if ext in (".svg",):
        return _load_svg(path)
    if ext in (".ai", ".pdf"):
        img = render_pdf_page(path)
        if img is not None:
            arr, alpha = _pil_to_rgba(_fit(img))
            return Visual(frames=[arr], source_alpha=alpha)

    try:
        from PIL import Image, ImageOps

        try:  # HEIC/HEIF/AVIF when the optional plugin is installed
            import pillow_heif  # type: ignore

            pillow_heif.register_heif_opener()
        except Exception:
            pass

        with Image.open(path) as im:
            n_frames = getattr(im, "n_frames", 1)
            im = ImageOps.exif_transpose(im)
            if n_frames > 1 and ext in (".gif", ".webp"):
                # An animated GIF is closer to a video than a still: take a
                # few frames across it, the way a clip is sampled.
                frames = []
                picks = sorted({int(i) for i in np.linspace(0, n_frames - 1, min(n_frames, 8))})
                had_alpha = False
                for i in picks:
                    im.seek(i)
                    arr, a = _pil_to_rgba(_fit(im.copy()))
                    had_alpha |= a
                    frames.append(arr)
                v = Visual(frames=frames, source_alpha=had_alpha)
                v.extra["animated_frames"] = n_frames
                return v
            arr, alpha = _pil_to_rgba(_fit(im))
            return Visual(frames=[arr], source_alpha=alpha)
    except Exception:
        pass

    # Pillow could not read it (EXR, some TIFFs, JXL without a plugin):
    # ffmpeg reads a surprising number of still formats.
    frame = _ffmpeg_frame(path, 0.0, alpha=True)
    if frame is None:
        raise RuntimeError(f"could not read {path.name} as an image")
    return Visual(frames=[frame], source_alpha=bool((frame[..., 3] < 250).any()))


def _load_svg(path: Path) -> Visual:
    """SVG through resvg (MPL-2.0, a separate optional package).

    cairosvg and librsvg are LGPL and Ghostscript is AGPL; resvg is the one
    that is both correct and licensed for a closed product. Without it, SVGs
    are listed and searchable by name but not looked at.
    """
    try:
        import resvg_py  # type: ignore
        from PIL import Image
        import io

        png = resvg_py.svg_to_bytes(svg_path=str(path), width=FRAME_EDGE)
        img = Image.open(io.BytesIO(bytes(png)))
        arr, alpha = _pil_to_rgba(_fit(img))
        return Visual(frames=[arr], source_alpha=alpha)
    except ImportError:
        raise RuntimeError("SVG needs the optional resvg_py package (pip install resvg-py)")


def render_pdf_page(path: Path, page: int = 0, edge: int = FRAME_EDGE):
    """First page of a PDF (or a PDF-compatible .ai) as a PIL image."""
    try:
        import pypdfium2 as pdfium  # Apache-2.0 / BSD-3; PDFium is BSD-3

        pdf = pdfium.PdfDocument(str(path))
        try:
            if len(pdf) == 0:
                return None
            p = pdf[min(page, len(pdf) - 1)]
            w, h = p.get_size()
            scale = edge / max(w, h, 1)
            return p.render(scale=scale).to_pil()
        finally:
            pdf.close()
    except Exception:
        return None


# ── video ───────────────────────────────────────────────────────────────────

def probe_video(path: Path) -> Probe:
    out = _run([A.FFPROBE, "-v", "error", "-print_format", "json", "-show_format",
                "-show_streams", str(path)], text=True)
    if out.returncode != 0:
        raise RuntimeError(f"ffprobe could not read {path.name}")
    doc = json.loads(out.stdout or "{}")
    p = Probe()
    try:
        p.duration = float(doc.get("format", {}).get("duration") or 0)
    except ValueError:
        p.duration = 0.0
    for s in doc.get("streams", []):
        if s.get("codec_type") == "audio":
            p.has_audio = True
        if s.get("codec_type") != "video" or p.width:
            continue
        if (s.get("disposition") or {}).get("attached_pic"):
            continue  # cover art in an audio file is not a video
        p.width = int(s.get("width") or 0)
        p.height = int(s.get("height") or 0)
        p.codec = s.get("codec_name", "")
        p.pix_fmt = s.get("pix_fmt", "")
        try:
            num, den = (s.get("avg_frame_rate") or s.get("r_frame_rate") or "0/1").split("/")
            p.fps = float(num) / float(den) if float(den) else 0.0
        except ValueError:
            p.fps = 0.0
        p.frames = int(s.get("nb_frames") or 0)
        tags = {k.lower(): v for k, v in (s.get("tags") or {}).items()}
        # yuva*, rgba, argb, bgra, gbrap, ya8... all carry alpha. VP8/VP9 in
        # WebM keep it in a side stream that ffprobe reports as a tag.
        fmt = p.pix_fmt.lower()
        p.has_alpha = ("yuva" in fmt or "rgba" in fmt or "argb" in fmt or "bgra" in fmt
                       or "abgr" in fmt or fmt.startswith("gbrap") or fmt.startswith("ya")
                       or tags.get("alpha_mode") == "1")
        p.hdr = s.get("color_transfer", "") in ("smpte2084", "arib-std-b67")
        if not p.duration:
            try:
                p.duration = float(s.get("duration") or 0)
            except ValueError:
                pass
    return p


def _decoder_args(path: Path, probe: Probe | None) -> list[str]:
    # VP8/VP9 alpha is only decoded by libvpx, not ffmpeg's native decoder.
    if probe and probe.has_alpha and probe.codec in ("vp8", "vp9"):
        return ["-c:v", "libvpx-vp9" if probe.codec == "vp9" else "libvpx"]
    return []


def _ffmpeg_frame(path: Path, at: float, alpha: bool = True, probe: Probe | None = None,
                  edge: int = FRAME_EDGE) -> np.ndarray | None:
    """One RGBA frame at `at` seconds, long edge at most `edge`."""
    scale = f"scale='min({edge},iw)':'min({edge},ih)':force_original_aspect_ratio=decrease"
    cmd = [A.FFMPEG, "-v", "error", "-nostdin"]
    if at > 0:
        cmd += ["-ss", f"{at:.3f}"]
    cmd += _decoder_args(path, probe)
    cmd += ["-i", str(path), "-frames:v", "1", "-vf", scale,
            "-f", "image2pipe", "-vcodec", "png", "-"]
    out = _run(cmd)
    if out.returncode != 0 or not out.stdout:
        return None
    from PIL import Image
    import io

    try:
        img = Image.open(io.BytesIO(out.stdout))
        arr, _ = _pil_to_rgba(img)
        return arr
    except Exception:
        return None


def tiny_frames(path: Path, probe: Probe, rate: float = 0.0, max_points: int = 2400) -> tuple[np.ndarray, float]:
    """The whole clip at 32x18 grey pixels, `rate` frames a second.

    An hour of video costs about as much as a handful of full frames. A flash,
    a cut, a fade, camera movement and a loop point all show up at this size;
    see mtag/media/measure.py. Returns (n, 18, 32) floats in 0..1.
    """
    if probe.duration <= 0:
        return np.zeros((0, 18, 32), dtype=np.float32), 0.0
    # Every frame when the clip is short enough: a muzzle flash is one or two
    # frames long, and sampling below the clip's own rate steps over it.
    if rate <= 0:
        rate = min(probe.fps or 24.0, 60.0)
    rate = min(rate, max_points / max(probe.duration, 1e-3))
    rate = max(rate, 0.05)
    cmd = [A.FFMPEG, "-v", "error", "-nostdin"] + _decoder_args(path, probe) + [
        "-i", str(path), "-an", "-vf", f"fps={rate:.5f},scale=32:18,format=gray",
        "-f", "rawvideo", "-"]
    out = _run(cmd)
    if out.returncode != 0:
        return np.zeros((0, 18, 32), dtype=np.float32), rate
    raw = np.frombuffer(out.stdout, dtype=np.uint8)
    n = raw.size // (32 * 18)
    return raw[: n * 32 * 18].reshape(n, 18, 32).astype(np.float32) / 255.0, rate


def load_video(path: Path, n_frames: int = 12) -> Visual:
    """Frames spread evenly across the clip, avoiding the very first and last
    moments, where fades and slates live."""
    probe = probe_video(path)
    if probe.width == 0:
        raise RuntimeError(f"{path.name} has no video stream")
    d = probe.duration
    if d <= 0:
        times = [0.0]
    elif d < 1.0:
        times = [d * f for f in (0.1, 0.5, 0.9)]
    else:
        n = max(1, min(n_frames, int(d * 2)))
        times = [d * (0.04 + 0.92 * i / max(n - 1, 1)) for i in range(n)]
    frames, kept = [], []
    for t in times:
        f = _ffmpeg_frame(path, t, probe=probe)
        if f is not None:
            frames.append(f)
            kept.append(t)
    if not frames:
        raise RuntimeError(f"no frames could be decoded from {path.name}")
    tiny, rate = tiny_frames(path, probe)

    # The brightest moment is often the whole point of an effects element,
    # and evenly spaced frames step straight over a two-frame flash. So the
    # peak is added to what the models see, unless a sampled frame is already
    # close to it.
    if len(tiny) >= 3 and rate > 0:
        luma = tiny.reshape(len(tiny), -1).mean(axis=1)
        peak = int(np.argmax(luma))
        at = peak / rate
        if luma[peak] - float(np.median(luma)) > 0.08 and all(abs(at - t) > 1.0 / rate for t in kept):
            f = _ffmpeg_frame(path, at, probe=probe)
            if f is not None:
                order = int(np.searchsorted(kept, at))
                frames.insert(order, f)
                kept.insert(order, at)

    v = Visual(frames=frames, times=kept, probe=probe, tiny=tiny,
               tiny_rate=rate, source_alpha=probe.has_alpha)
    # The true first and last frames, for the loop test. The sampled frames
    # stop short of both ends on purpose, so they cannot answer it.
    if 0 < d <= 120:
        first = _ffmpeg_frame(path, 0.0, probe=probe, edge=128)
        last_at = max(0.0, d - 1.5 / max(probe.fps, 1.0))
        last = _ffmpeg_frame(path, last_at, probe=probe, edge=128)
        if first is not None and last is not None:
            v.extra["first"], v.extra["last"] = first, last
    return v


# ── documents ───────────────────────────────────────────────────────────────

MAX_TEXT = 20000  # characters read from a document; enough to embed and summarise


def read_text(path: Path) -> str:
    """The text of a document, best effort, capped at MAX_TEXT characters."""
    ext = path.suffix.lower()
    try:
        if ext == ".pdf":
            import pypdfium2 as pdfium

            pdf = pdfium.PdfDocument(str(path))
            try:
                parts, total = [], 0
                for i in range(min(len(pdf), 30)):
                    page = pdf[i]
                    tp = page.get_textpage()
                    t = tp.get_text_range()
                    parts.append(t)
                    total += len(t)
                    if total > MAX_TEXT:
                        break
                return "\n".join(parts)[:MAX_TEXT]
            finally:
                pdf.close()
        if ext == ".docx":
            import docx  # python-docx, MIT

            d = docx.Document(str(path))
            return "\n".join(p.text for p in d.paragraphs)[:MAX_TEXT]
        if ext == ".odt":
            import zipfile
            import re

            with zipfile.ZipFile(path) as z:
                xml = z.read("content.xml").decode("utf-8", "replace")
            return re.sub(r"<[^>]+>", " ", xml)[:MAX_TEXT]
        if ext == ".rtf":
            import re

            raw = path.read_text(encoding="latin-1", errors="replace")
            raw = re.sub(r"\\'[0-9a-f]{2}", "", raw)
            raw = re.sub(r"\\[a-zA-Z]+-?\d* ?|[{}]", "", raw)
            return raw[:MAX_TEXT]
        if ext in (".srt", ".vtt"):
            import re

            raw = _read_plain(path)
            # Drop cue numbers and timings; what is said is the useful part.
            lines = [l for l in raw.splitlines()
                     if l.strip() and not l.strip().isdigit() and "-->" not in l
                     and not l.startswith("WEBVTT")]
            return re.sub(r"<[^>]+>", "", "\n".join(lines))[:MAX_TEXT]
        return _read_plain(path)[:MAX_TEXT]
    except Exception as e:
        raise RuntimeError(f"could not read text from {path.name}: {e}")


def _read_plain(path: Path) -> str:
    data = path.read_bytes()[: MAX_TEXT * 4]
    for enc in ("utf-8-sig", "utf-16", "cp1252", "latin-1"):
        try:
            text = data.decode(enc)
            if enc == "utf-16" and not data.startswith((b"\xff\xfe", b"\xfe\xff")):
                continue
            return text
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", "replace")


# ── dispatch ────────────────────────────────────────────────────────────────

def load_visual(path: Path, kind: str) -> Visual:
    if kind == K.IMAGE:
        return load_image(path)
    if kind == K.VIDEO:
        return load_video(path)
    if kind == K.MODEL:
        from .render3d import render_views

        views, info = render_views(path)
        v = Visual(frames=views)
        v.extra.update(info)
        return v
    if kind == K.DOCUMENT and path.suffix.lower() == ".pdf":
        img = render_pdf_page(path)
        if img is not None:
            arr, _ = _pil_to_rgba(_fit(img))
            return Visual(frames=[arr])
    return Visual()


def thumbnail_png(frame: np.ndarray, dest: Path, edge: int = 320) -> None:
    """A small PNG the front end can load directly (raylib has no JPEG)."""
    from PIL import Image

    img = Image.fromarray(frame, "RGBA")
    img.thumbnail((edge, edge), resample=3)
    dest.parent.mkdir(parents=True, exist_ok=True)
    img.save(dest, "PNG", optimize=False, compress_level=6)
