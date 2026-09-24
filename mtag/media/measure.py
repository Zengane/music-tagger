"""Tags that are measured, not guessed.

Whether a clip is keyed on green, has an alpha channel, sits on black for a
Screen blend, loops, flashes, or cuts — all of that is in the pixels and needs
no model. Measuring it is faster than any model, cannot hallucinate, and is
right far more often, so these tags are decided here and the models are only
asked about what cannot be measured: *what* the flash is of.

Everything works on RGBA uint8 frames and on the tiny grey frames from
decode.tiny_frames. Scores are 0..1; a measured tag that fires is given a
score well above its threshold so it applies itself.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

# Measured tags apply at this score; a clear pass is scored higher.
MEASURED_THRESHOLD = 0.5


@dataclass
class Measured:
    tags: dict[str, float] = field(default_factory=dict)
    metrics: dict = field(default_factory=dict)

    def add(self, tag: str, strength: float = 1.0) -> None:
        """Record a measured tag. `strength` 0..1 maps onto 0.6..1.0."""
        score = 0.6 + 0.4 * float(np.clip(strength, 0.0, 1.0))
        self.tags[tag] = max(self.tags.get(tag, 0.0), round(score, 4))


# ── colour space ────────────────────────────────────────────────────────────

def _hsv(rgb: np.ndarray):
    """rgb float 0..1 (..., 3) -> hue degrees, saturation, value."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx = rgb.max(axis=-1)
    mn = rgb.min(axis=-1)
    delta = mx - mn
    s = np.where(mx > 1e-6, delta / np.maximum(mx, 1e-6), 0.0)
    h = np.zeros_like(mx)
    nz = delta > 1e-6
    rc = np.where(nz, (mx - r) / np.maximum(delta, 1e-6), 0)
    gc = np.where(nz, (mx - g) / np.maximum(delta, 1e-6), 0)
    bc = np.where(nz, (mx - b) / np.maximum(delta, 1e-6), 0)
    h = np.where(r == mx, bc - gc, np.where(g == mx, 2.0 + rc - bc, 4.0 + gc - rc))
    h = (h / 6.0) % 1.0 * 360.0
    h = np.where(nz, h, 0.0)
    return h, s, mx


def _luma(rgb: np.ndarray) -> np.ndarray:
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


def _small(frame: np.ndarray, edge: int = 192) -> np.ndarray:
    """Nearest-neighbour shrink: plenty for fractions of pixels, and fast."""
    h, w = frame.shape[:2]
    step = max(1, int(np.ceil(max(h, w) / edge)))
    return frame[::step, ::step]


def _border_mask(h: int, w: int, frac: float = 0.06) -> np.ndarray:
    m = np.zeros((h, w), dtype=bool)
    bh, bw = max(1, int(h * frac)), max(1, int(w * frac))
    m[:bh, :] = m[-bh:, :] = True
    m[:, :bw] = m[:, -bw:] = True
    return m


# ── keying, backgrounds, transparency ───────────────────────────────────────

# Above this, a green or blue area is texture (foliage, water), not a screen.
# Real screens measured by the tests sit near 0.02-0.08, even with a light
# falloff across them and compression noise; a leafy texture sits well over 0.2.
KEY_ROUGHNESS = 0.16


def _local_roughness(val: np.ndarray, sel: np.ndarray) -> float:
    """Mean brightness change between neighbouring pixels inside `sel`.

    Standard deviation alone forgives a screen lit brighter on one side, but
    it also forgives nothing about texture; pixel-to-pixel change is what
    tells leaves from a painted wall."""
    dx = np.abs(np.diff(val, axis=1))[sel[:, 1:] & sel[:, :-1]]
    dy = np.abs(np.diff(val, axis=0))[sel[1:, :] & sel[:-1, :]]
    both = np.concatenate([dx, dy])
    return float(both.mean()) * 2.0 if both.size else 0.0

def classify_pixels(rgb: np.ndarray) -> dict[str, np.ndarray]:
    """Boolean masks for the backgrounds an editor keys or blends out."""
    h, s, v = _hsv(rgb)
    y = _luma(rgb)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    return {
        # Chroma green: saturated, reasonably lit, and green clearly on top.
        "green": (h >= 75) & (h <= 165) & (s >= 0.35) & (v >= 0.22) & (g > r * 1.25) & (g > b * 1.1),
        "blue": (h >= 190) & (h <= 250) & (s >= 0.40) & (v >= 0.20) & (b > r * 1.4) & (b > g * 1.05),
        "black": y < 0.07,
        "white": (y > 0.92) & (s < 0.12),
    }


def keying(frames: list[np.ndarray], source_alpha: bool, out: Measured,
           tiny: np.ndarray | None = None) -> None:
    """Alpha, green/blue screen, and black or white backgrounds.

    Decided per frame on the border and on the whole picture, then by the
    median across frames: a muzzle flash is black for most of its length and
    that is exactly what makes it a Screen-blend element.
    """
    if not frames:
        return
    stats = {k: [] for k in ("green", "blue", "black", "white")}
    # How evenly lit the green and blue areas are. A key screen is lit flat on
    # purpose; grass, leaves and water are not. Without this a meadow photo
    # passes for a green screen.
    evenness = {"green": [], "blue": []}
    border_stats = {k: [] for k in stats}
    transparent, content = [], []
    for f in frames:
        f = _small(f)
        rgb = f[..., :3].astype(np.float32) / 255.0
        alpha = f[..., 3]
        opaque = alpha >= 128
        transparent.append(float((alpha < 16).mean()))
        masks = classify_pixels(rgb)
        border = _border_mask(*f.shape[:2]) & opaque
        n_op, n_bd = max(int(opaque.sum()), 1), max(int(border.sum()), 1)
        for k, m in masks.items():
            stats[k].append(float((m & opaque).sum()) / n_op)
            border_stats[k].append(float((m & border).sum()) / n_bd)
        _, _, val = _hsv(rgb)
        for k in evenness:
            sel = masks[k] & opaque
            if sel.sum() >= 64:
                evenness[k].append(float(val[sel].std()) + _local_roughness(val, sel))
        # Something bright on the background: the element itself.
        content.append(float(((_luma(rgb) > 0.25) & opaque).sum()) / n_op)

    med = {k: float(np.median(v)) for k, v in stats.items()}
    bmed = {k: float(np.median(v)) for k, v in border_stats.items()}
    out.metrics.update({f"frac_{k}": round(v, 3) for k, v in med.items()})
    out.metrics.update({f"border_{k}": round(v, 3) for k, v in bmed.items()})

    t = float(np.median(transparent))
    out.metrics["frac_transparent"] = round(t, 3)
    if source_alpha and max(transparent) >= 0.02:
        out.add("Alpha-Channel", min(1.0, max(transparent) * 4))

    rough = {k: (float(np.median(v)) if v else 1.0) for k, v in evenness.items()}
    out.metrics["key_roughness"] = {k: round(v, 3) for k, v in rough.items()}
    if bmed["green"] >= 0.5 and med["green"] >= 0.2 and rough["green"] <= KEY_ROUGHNESS:
        out.add("Green-Screen", bmed["green"])
    if bmed["blue"] >= 0.5 and med["blue"] >= 0.2 and rough["blue"] <= KEY_ROUGHNESS:
        out.add("Blue-Screen", bmed["blue"])

    # A flash can fall between every sampled frame; the tiny frames see all.
    tiny_content = tiny is not None and len(tiny) and float(tiny.max()) > 0.25
    has_content = max(content) >= 0.003 or bool(tiny_content)
    if bmed["black"] >= 0.85 and med["black"] >= 0.45 and has_content:
        # Black drops out under Screen or Add. That is the useful fact.
        out.add("Black-Background", (bmed["black"] - 0.85) / 0.15)
    if bmed["white"] >= 0.85 and med["white"] >= 0.35:
        # White drops out under Multiply; for a stock photo it means isolated.
        out.add("White-Background", (bmed["white"] - 0.85) / 0.15)


# ── colour ──────────────────────────────────────────────────────────────────

# Hue ranges for plain colour names, in degrees. Red wraps around zero.
_HUES = (
    ("Red", 345, 15), ("Orange", 15, 40), ("Yellow", 40, 68), ("Green", 68, 165),
    ("Teal", 165, 195), ("Blue", 195, 255), ("Purple", 255, 290), ("Pink", 290, 345),
)


def colours(frames: list[np.ndarray], out: Measured, skip_background: bool) -> None:
    """Dominant colours by share of pixels, plus black-and-white and tone."""
    if not frames:
        return
    counts: dict[str, float] = {}
    sats, lumas = [], []
    total = 0.0
    for f in frames:
        f = _small(f, 128)
        rgb = f[..., :3].astype(np.float32) / 255.0
        keep = f[..., 3] >= 128
        if skip_background:
            m = classify_pixels(rgb)
            keep &= ~(m["green"] | m["blue"] | m["black"] | m["white"])
        if keep.sum() < 16:
            continue
        px = rgb[keep]
        h, s, v = _hsv(px)
        y = _luma(px)
        sats.append(float(s.mean()))
        lumas.append(float(y.mean()))
        chroma = (s >= 0.25) & (v >= 0.2)
        total += float(px.shape[0])
        for name, lo, hi in _HUES:
            sel = (h >= lo) | (h < hi) if lo > hi else (h >= lo) & (h < hi)
            counts[name] = counts.get(name, 0.0) + float((sel & chroma).sum())
        # Brown is dark orange; it is how wood, skin and earth read.
        brown = chroma & (h >= 10) & (h < 45) & (v < 0.55)
        counts["Brown"] = counts.get("Brown", 0.0) + float(brown.sum())
        counts["Orange"] -= float(brown.sum() * 0.8)

    if total == 0:
        return
    shares = {k: max(v, 0.0) / total for k, v in counts.items()}
    out.metrics["colours"] = {k: round(v, 3) for k, v in sorted(shares.items(), key=lambda kv: -kv[1]) if v >= 0.02}
    for name, share in shares.items():
        if share >= 0.22:
            out.add(name, (share - 0.22) / 0.5)

    sat = float(np.mean(sats)) if sats else 0.0
    lum = float(np.mean(lumas)) if lumas else 0.0
    out.metrics["saturation"] = round(sat, 3)
    out.metrics["brightness"] = round(lum, 3)
    if sat < 0.05:
        out.add("Black-and-White", 1.0 - sat / 0.05)
    elif sat > 0.5:
        out.add("Colourful", (sat - 0.5) / 0.3)


# ── time: flashes, fades, cuts, motion, loops ───────────────────────────────

def _cuts(tiny: np.ndarray) -> list[int]:
    """Indices i where frame i+1 is a different shot from frame i.

    A cut changes the *structure* of the picture; a flash or a fade changes its
    brightness and leaves the structure where it was. So the test is
    normalised correlation between neighbouring frames, which ignores overall
    brightness, and a frame that is nearly flat (black, or one colour) is never
    the side of a cut — that is a fade or a flash from black.
    """
    flat = tiny.reshape(len(tiny), -1)
    centred = flat - flat.mean(axis=1, keepdims=True)
    std = centred.std(axis=1)
    diff = np.abs(np.diff(flat, axis=0)).mean(axis=1)
    typical = float(np.median(diff)) + 1e-4
    cuts = []
    for i in range(len(flat) - 1):
        if std[i] < 0.03 or std[i + 1] < 0.03:
            continue
        ncc = float((centred[i] * centred[i + 1]).mean() / (std[i] * std[i + 1]))
        if ncc < 0.5 and diff[i] > 0.04 and diff[i] > typical * 3:
            cuts.append(i)
    return cuts


def temporal(tiny: np.ndarray, rate: float, out: Measured) -> None:
    """What happens over time, from the 32x18 grey frames."""
    if tiny is None or len(tiny) < 3 or rate <= 0:
        return
    flat = tiny.reshape(len(tiny), -1)
    luma = flat.mean(axis=1)
    diff = np.abs(np.diff(flat, axis=0)).mean(axis=1)
    out.metrics["luma_mean"] = round(float(luma.mean()), 3)
    cuts = _cuts(tiny)
    cut_set = set(cuts)

    # Flashes are read from the brightest 3x3 patch of each frame, not the
    # frame's mean: a muzzle flash covers a few percent of the picture and
    # barely moves the average.
    patches = np.lib.stride_tricks.sliding_window_view(tiny, (3, 3), axis=(1, 2)).mean(axis=(-1, -2))
    luma = patches.reshape(len(tiny), -1).max(axis=1)

    # Flashes: a jump well above the recent baseline that falls away again.
    # A muzzle flash lasts a frame or two; an explosion rises as fast and
    # decays over a good part of a second. The decay is recorded so the two
    # can be told apart when the model is asked what the flash is of.
    window = max(2, int(rate * 1.0))
    flashes = []
    i = 1
    while i < len(luma):
        base = float(np.median(luma[max(0, i - window):i]))
        rise = float(luma[i] - base)
        if rise >= 0.25 and luma[i] >= 0.35 and (i - 1) not in cut_set:
            peak_i = i
            while peak_i + 1 < len(luma) and luma[peak_i + 1] >= luma[peak_i]:
                peak_i += 1
            peak = float(luma[peak_i])
            half = base + (peak - base) * 0.5
            j = peak_i
            while j + 1 < len(luma) and luma[j] > half:
                j += 1
            ends = j + 1 < len(luma) or luma[j] <= half
            if ends:  # a step up that never comes down is a new shot, not a flash
                flashes.append({"at": round(i / rate, 3), "rise": round(peak - base, 3),
                                "decay": round((j - peak_i + 1) / rate, 3)})
            i = j + 1
            continue
        i += 1
    if flashes:
        out.metrics["flashes"] = flashes[:20]
        strongest = max(f["rise"] for f in flashes)
        out.add("Flash", min(1.0, strongest / 0.6))
        if any(f["decay"] <= 0.15 for f in flashes):
            out.metrics["short_flash"] = True
        if any(f["decay"] >= 0.3 for f in flashes):
            out.metrics["long_flash"] = True

    luma = flat.mean(axis=1)

    # Fades: starting or ending in black, with picture in between.
    head = float(luma[: max(1, int(rate * 0.2))].mean())
    tail = float(luma[-max(1, int(rate * 0.2)):].mean())
    body = float(np.percentile(luma, 75))
    if head < 0.03 and body > 0.1:
        out.add("Fade-In", (body - head) / 0.3)
    if tail < 0.03 and body > 0.1:
        out.add("Fade-Out", (body - tail) / 0.3)

    duration = len(tiny) / rate
    out.metrics["cuts"] = len(cuts)
    out.metrics["cuts_per_minute"] = round(len(cuts) / max(duration / 60.0, 1e-3), 2)
    if not cuts and duration >= 2.0:
        out.add("Single-Shot", 1.0)
    elif len(cuts) >= 3 and len(cuts) / max(duration / 60, 1e-3) >= 12:
        out.add("Montage", min(1.0, len(cuts) / 20))

    # Motion within shots: the typical change between frames, cuts excluded.
    within = np.delete(diff, cuts) if cuts else diff
    motion = float(np.median(within)) if len(within) else 0.0
    out.metrics["motion"] = round(motion, 4)
    if motion < 0.004 and not flashes:
        out.add("Static-Shot", 1.0 - motion / 0.004)
    elif motion > 0.04:
        out.add("High-Motion", min(1.0, (motion - 0.04) / 0.06))


def loop(first: np.ndarray | None, last: np.ndarray | None, out: Measured) -> None:
    """A loop's last frame leads straight back into its first."""
    if first is None or last is None:
        return
    a = _small(first, 64).astype(np.float32) / 255.0
    b = _small(last, 64).astype(np.float32) / 255.0
    hh, ww = min(a.shape[0], b.shape[0]), min(a.shape[1], b.shape[1])
    d = float(np.abs(a[:hh, :ww] - b[:hh, :ww]).mean())
    out.metrics["loop_distance"] = round(d, 4)
    # An all-black start and end is a fade, not a loop.
    if d < 0.03 and float(a[..., :3].mean()) > 0.04:
        out.add("Loop", 1.0 - d / 0.03)


def video_format(probe, out: Measured) -> None:
    """Facts from the container: orientation, size, frame rate, HDR."""
    if probe is None or not probe.width:
        return
    w, h = probe.width, probe.height
    out.metrics.update({"width": w, "height": h, "fps": round(probe.fps, 3),
                        "duration": round(probe.duration, 3), "codec": probe.codec,
                        "has_audio": probe.has_audio})
    if h > w * 1.2:
        out.add("Vertical", 1.0)
    if max(w, h) >= 3800:
        out.add("4K", 1.0)
    if probe.fps >= 90:
        # Shot fast: slows down cleanly in an edit.
        out.add("High-Frame-Rate", min(1.0, probe.fps / 240))
    if probe.hdr:
        out.add("HDR", 1.0)


def image_format(frames: list[np.ndarray], out: Measured) -> None:
    if not frames:
        return
    h, w = frames[0].shape[:2]
    out.metrics.update({"width": w, "height": h})
    if h > w * 1.2:
        out.add("Vertical", 1.0)


def measure(visual, kind: str) -> Measured:
    """All measurements that apply to `visual`."""
    out = Measured()
    keying(visual.frames, visual.source_alpha, out, visual.tiny)
    keyed = any(t in out.tags for t in ("Green-Screen", "Blue-Screen", "Black-Background", "White-Background"))
    colours(visual.frames, out, skip_background=keyed or visual.source_alpha)
    if kind == "video":
        video_format(visual.probe, out)
        temporal(visual.tiny, visual.tiny_rate, out)
        loop(visual.extra.get("first"), visual.extra.get("last"), out)
        if out.metrics.get("duration", 0) and out.metrics["duration"] <= 6:
            out.add("Short-Element", 1.0)
    elif kind == "image":
        image_format(visual.frames, out)
        if visual.extra.get("animated_frames"):
            out.add("Animated", 1.0)
    return out


# Every tag this module can produce, by group, for the front end's vocabulary.
MEASURED_GROUPS: dict[str, list[str]] = {
    "Keying": ["Alpha-Channel", "Green-Screen", "Blue-Screen", "Black-Background", "White-Background"],
    "Colour": ["Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink", "Brown",
               "Black-and-White", "Colourful"],
    "Footage": ["Flash", "Fade-In", "Fade-Out", "Loop", "Single-Shot", "Montage", "Static-Shot",
                "High-Motion", "Short-Element", "Vertical", "4K", "High-Frame-Rate", "HDR", "Animated"],
    "3D-Facts": ["Rigged", "Textured", "Low-Poly"],
    "Text": ["Has-Text"],
}
