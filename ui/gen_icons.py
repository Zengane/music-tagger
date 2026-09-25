"""Adds Lucide icons to icondata.odin.

    python ui/gen_icons.py <lucide-static/icons folder>

Lucide (https://lucide.dev, ISC licence) draws every icon as strokes on a
24 by 24 grid. This flattens each SVG's paths, circles, rects and lines to
polylines and appends them to the tables in icondata.odin. Icons already in
the file are kept exactly as they are; only names in NEW that are missing
from ICON_SHAPES are added. The Icon enum in icons.odin must list them.
"""

from __future__ import annotations

import math
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE / "icondata.odin"

# Icon enum name -> Lucide file name.
NEW = {
    "Music": "music",
    "Sfx": "audio-waveform",
    "Image": "image",
    "Video": "clapperboard",
    "Model": "box",
    "Document": "file-text",
    "Layers": "layers",
    "List": "list",
    "Grid": "layout-grid",
    "Sort_Up": "arrow-up-narrow-wide",
    "Sort_Down": "arrow-down-wide-narrow",
    "Library": "library",
    "Map": "map",
    "Tag": "tag",
    "Sparkles": "sparkles",
    "Save": "save",
    "Undo": "undo-2",
    "Refresh": "refresh-cw",
    "Folder_Open": "folder-open",
    "Expand": "maximize-2",
    "Rotate": "rotate-3d",
    "Info": "info",
    "Cpu": "cpu",
    "Drive": "hard-drive",
    "File": "file",
    "Zoom_In": "zoom-in",
    "Zoom_Out": "zoom-out",
    "Up_Folder": "corner-left-up",
    "Folder_Tree": "folder-tree",
}

CURVE_STEPS = 10


def arc_points(x1, y1, rx, ry, phi, fa, fs, x2, y2):
    """SVG endpoint arc -> points (excluding the start)."""
    if rx == 0 or ry == 0:
        return [(x2, y2)]
    rx, ry = abs(rx), abs(ry)
    cp, sp = math.cos(math.radians(phi)), math.sin(math.radians(phi))
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    lam = (x1p ** 2) / rx ** 2 + (y1p ** 2) / ry ** 2
    if lam > 1:
        rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num = rx ** 2 * ry ** 2 - rx ** 2 * y1p ** 2 - ry ** 2 * x1p ** 2
    den = rx ** 2 * y1p ** 2 + ry ** 2 * x1p ** 2
    co = math.sqrt(max(num / den, 0)) if den else 0
    if fa == fs:
        co = -co
    cxp, cyp = co * rx * y1p / ry, -co * ry * x1p / rx
    cx = cp * cxp - sp * cyp + (x1 + x2) / 2
    cy = sp * cxp + cp * cyp + (y1 + y2) / 2

    def ang(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a

    t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not fs and dt > 0:
        dt -= 2 * math.pi
    elif fs and dt < 0:
        dt += 2 * math.pi
    steps = max(2, int(abs(dt) / (math.pi / 12)) + 1)
    out = []
    for i in range(1, steps + 1):
        t = t1 + dt * i / steps
        x = cx + rx * math.cos(t) * cp - ry * math.sin(t) * sp
        y = cy + rx * math.cos(t) * sp + ry * math.sin(t) * cp
        out.append((x, y))
    return out


def path_strokes(d: str):
    tokens = re.findall(r"[MmLlHhVvCcSsQqTtAaZz]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?", d)
    strokes, cur = [], []
    x = y = sx = sy = 0.0
    last_ctrl = None
    cmd = None
    i = 0

    def num():
        nonlocal i
        v = float(tokens[i])
        i += 1
        return v

    def flush(closed=False):
        nonlocal cur
        if len(cur) >= 2:
            strokes.append((cur, closed))
        cur = []

    while i < len(tokens):
        if re.match(r"[A-Za-z]", tokens[i]):
            cmd = tokens[i]
            i += 1
            if cmd in "Zz":
                if cur:
                    cur.append((sx, sy))
                flush(True)
                x, y = sx, sy
                continue
        rel = cmd.islower()
        c = cmd.upper()
        if c == "M":
            flush()
            nx, ny = num(), num()
            x, y = (x + nx, y + ny) if rel else (nx, ny)
            sx, sy = x, y
            cur = [(x, y)]
            cmd = "l" if rel else "L"
            last_ctrl = None
        elif c == "L":
            nx, ny = num(), num()
            x, y = (x + nx, y + ny) if rel else (nx, ny)
            cur.append((x, y))
            last_ctrl = None
        elif c == "H":
            nx = num()
            x = x + nx if rel else nx
            cur.append((x, y))
            last_ctrl = None
        elif c == "V":
            ny = num()
            y = y + ny if rel else ny
            cur.append((x, y))
            last_ctrl = None
        elif c in "CS":
            if c == "C":
                x1, y1 = num(), num()
                if rel:
                    x1, y1 = x + x1, y + y1
            else:
                x1, y1 = (2 * x - last_ctrl[0], 2 * y - last_ctrl[1]) if last_ctrl else (x, y)
            x2, y2, ex, ey = num(), num(), num(), num()
            if rel:
                x2, y2, ex, ey = x + x2, y + y2, x + ex, y + ey
            for k in range(1, CURVE_STEPS + 1):
                t = k / CURVE_STEPS
                mt = 1 - t
                px_ = mt ** 3 * x + 3 * mt * mt * t * x1 + 3 * mt * t * t * x2 + t ** 3 * ex
                py_ = mt ** 3 * y + 3 * mt * mt * t * y1 + 3 * mt * t * t * y2 + t ** 3 * ey
                cur.append((px_, py_))
            last_ctrl = (x2, y2)
            x, y = ex, ey
        elif c in "QT":
            if c == "Q":
                x1, y1 = num(), num()
                if rel:
                    x1, y1 = x + x1, y + y1
            else:
                x1, y1 = (2 * x - last_ctrl[0], 2 * y - last_ctrl[1]) if last_ctrl else (x, y)
            ex, ey = num(), num()
            if rel:
                ex, ey = x + ex, y + ey
            for k in range(1, CURVE_STEPS + 1):
                t = k / CURVE_STEPS
                mt = 1 - t
                cur.append((mt * mt * x + 2 * mt * t * x1 + t * t * ex,
                            mt * mt * y + 2 * mt * t * y1 + t * t * ey))
            last_ctrl = (x1, y1)
            x, y = ex, ey
        elif c == "A":
            rx, ry, phi, fa, fs, ex, ey = num(), num(), num(), num(), num(), num(), num()
            if rel:
                ex, ey = x + ex, y + ey
            cur.extend(arc_points(x, y, rx, ry, phi, int(fa), int(fs), ex, ey))
            x, y = ex, ey
            last_ctrl = None
    flush()
    return strokes


def ellipse(cx, cy, rx, ry):
    n = 36
    pts = [(cx + rx * math.cos(2 * math.pi * k / n), cy + ry * math.sin(2 * math.pi * k / n)) for k in range(n)]
    pts.append(pts[0])
    return [(pts, True)]


def rounded_rect(x, y, w, h, rx, ry):
    if rx == 0 and ry == 0:
        pts = [(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)]
        return [(pts, True)]
    rx = min(rx or ry, w / 2)
    ry = min(ry or rx, h / 2)
    pts = []
    corners = [(x + w - rx, y + ry, -90), (x + w - rx, y + h - ry, 0), (x + rx, y + h - ry, 90), (x + rx, y + ry, 180)]
    for cx, cy, start in corners:
        for k in range(7):
            a = math.radians(start + 90 * k / 6)
            pts.append((cx + rx * math.cos(a), cy + ry * math.sin(a)))
    pts.append(pts[0])
    return [(pts, True)]


def svg_strokes(path: Path):
    root = ET.parse(path).getroot()
    out = []
    for el in root.iter():
        tag = el.tag.split("}")[-1]
        a = {k: v for k, v in el.attrib.items()}
        f = lambda k, d=0.0: float(a.get(k, d))
        if tag == "path":
            out += path_strokes(a["d"])
        elif tag == "circle":
            out += ellipse(f("cx"), f("cy"), f("r"), f("r"))
        elif tag == "ellipse":
            out += ellipse(f("cx"), f("cy"), f("rx"), f("ry"))
        elif tag == "rect":
            out += rounded_rect(f("x"), f("y"), f("width"), f("height"), f("rx"), f("ry"))
        elif tag == "line":
            out.append(([(f("x1"), f("y1")), (f("x2"), f("y2"))], False))
        elif tag in ("polyline", "polygon"):
            nums = [float(v) for v in re.findall(r"-?\d*\.?\d+", a["points"])]
            pts = list(zip(nums[0::2], nums[1::2]))
            if tag == "polygon":
                pts.append(pts[0])
            out.append((pts, tag == "polygon"))
    return out


def main():
    icons_dir = Path(sys.argv[1])
    text = DATA.read_text(encoding="utf-8")

    pts_block = re.search(r"ICON_POINTS := \[(\d+)\]\[2\]f32\{(.*?)\n\}", text, re.S)
    points = [(float(a), float(b)) for a, b in re.findall(r"\{(-?[\d.]+), (-?[\d.]+)\}", pts_block.group(2))]
    str_block = re.search(r"ICON_STROKES := \[(\d+)\]Icon_Stroke\{(.*?)\n\}", text, re.S)
    strokes = [(int(a), int(b), c == "true") for a, b, c in re.findall(r"\{(\d+), (\d+), (true|false)\}", str_block.group(2))]
    shape_block = re.search(r"ICON_SHAPES := \[Icon\]Icon_Shape\{(.*?)\n\}", text, re.S)
    shapes = re.findall(r"\.(\w+) = \{(\d+), (\d+)\}", shape_block.group(1))
    known = {name for name, _, _ in shapes}

    for name, file in NEW.items():
        if name in known:
            continue
        first = len(strokes)
        for pts, closed in svg_strokes(icons_dir / f"{file}.svg"):
            strokes.append((len(points), len(pts), closed))
            points.extend(pts)
        shapes.append((name, str(first), str(len(strokes) - first)))

    def rows(items, per):
        return "\n".join("\t" + " ".join(items[i:i + per]) for i in range(0, len(items), per))

    p_items = [f"{{{x:.3f}, {y:.3f}}}," for x, y in points]
    s_items = [f"{{{a}, {b}, {'true' if c else 'false'}}}," for a, b, c in strokes]
    new_pts = f"ICON_POINTS := [{len(points)}][2]f32{{\n{rows(p_items, 4)}\n}}"
    new_str = f"ICON_STROKES := [{len(strokes)}]Icon_Stroke{{\n{rows(s_items, 1)}\n}}"
    new_shapes = "ICON_SHAPES := [Icon]Icon_Shape{\n" + "\n".join(
        f"\t.{n} = {{{a}, {b}}}," for n, a, b in shapes) + "\n}"
    text = text[:pts_block.start()] + new_pts + text[pts_block.end():]
    str_block = re.search(r"ICON_STROKES := \[(\d+)\]Icon_Stroke\{(.*?)\n\}", text, re.S)
    text = text[:str_block.start()] + new_str + text[str_block.end():]
    shape_block = re.search(r"ICON_SHAPES := \[Icon\]Icon_Shape\{(.*?)\n\}", text, re.S)
    text = text[:shape_block.start()] + new_shapes + text[shape_block.end():]
    DATA.write_text(text, encoding="utf-8")
    print(f"{len(shapes)} icons, {len(strokes)} strokes, {len(points)} points")


if __name__ == "__main__":
    main()
