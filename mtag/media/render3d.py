"""Pictures of a 3D model, so the image models can say what it is.

The model is loaded with trimesh (MIT) and drawn from four angles by a small
point-splatting renderer written in numpy. No OpenGL is involved, which is the
point: pyrender and friends need a GL context, and a GL context is exactly the
thing that differs between Windows, macOS, a Linux desktop and a headless job.
A few hundred thousand shaded points are plenty for a picture that an image
model can recognise, and that is all these views are for.

Formats trimesh reads directly: glTF/GLB, OBJ, STL, PLY, OFF, 3MF, and DAE when
pycollada is installed. FBX, .blend, USD and Alembic go through Blender when it
is installed (GPL, so it is called as a separate program, never bundled): set
MUSICTAGGER_BLENDER to its path or put it on PATH.
"""

from __future__ import annotations

import json
import os
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

import numpy as np

VIEW_SIZE = 384
POINTS = 260_000
# Yaw, pitch in degrees. Three-quarter views read best; the fourth is the back.
VIEWS = ((35, 20), (125, 20), (215, 20), (305, 35))

NEEDS_BLENDER = {".fbx", ".blend", ".usd", ".usda", ".usdc", ".usdz", ".abc"}


def blender_path() -> str | None:
    env = os.environ.get("MUSICTAGGER_BLENDER")
    if env and Path(env).exists():
        return env
    found = shutil.which("blender")
    if found:
        return found
    for guess in ("/Applications/Blender.app/Contents/MacOS/Blender",
                  r"C:\Program Files\Blender Foundation\Blender\blender.exe"):
        if Path(guess).exists():
            return guess
    return None


_BLENDER_EXPORT = r"""
import bpy, sys
src, dst = sys.argv[sys.argv.index("--") + 1:][:2]
bpy.ops.wm.read_factory_settings(use_empty=True)
ext = src.lower().rsplit(".", 1)[-1]
if ext == "blend":
    bpy.ops.wm.open_mainfile(filepath=src)
elif ext == "fbx":
    bpy.ops.import_scene.fbx(filepath=src)
elif ext in ("usd", "usda", "usdc", "usdz"):
    bpy.ops.wm.usd_import(filepath=src)
elif ext == "abc":
    bpy.ops.wm.alembic_import(filepath=src)
bpy.ops.export_scene.gltf(filepath=dst, export_format="GLB")
"""


def _via_blender(path: Path) -> Path:
    blender = blender_path()
    if not blender:
        raise RuntimeError(f"{path.suffix} files need Blender installed (set MUSICTAGGER_BLENDER)")
    tmp = Path(tempfile.mkdtemp(prefix="mt3d-"))
    script = tmp / "export.py"
    script.write_text(_BLENDER_EXPORT, encoding="utf-8")
    out = tmp / "model.glb"
    kw = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
    subprocess.run([blender, "-b", "--factory-startup", "-P", str(script), "--", str(path), str(out)],
                   capture_output=True, timeout=300, **kw)
    if not out.exists():
        raise RuntimeError(f"Blender could not convert {path.name}")
    return out


def gltf_facts(path: Path) -> dict:
    """Rigged? Animated? Read straight from the glTF JSON, which trimesh drops."""
    try:
        raw = path.read_bytes()
        if raw[:4] == b"glTF":
            length = struct.unpack_from("<I", raw, 12)[0]
            doc = json.loads(raw[20:20 + length])
        else:
            doc = json.loads(raw.decode("utf-8"))
    except Exception:
        return {}
    return {
        "rigged": bool(doc.get("skins")),
        "animated": bool(doc.get("animations")),
        "animations": len(doc.get("animations") or []),
        "morph_targets": any(p.get("targets") for m in doc.get("meshes", []) for p in m.get("primitives", [])),
        "materials": len(doc.get("materials") or []),
        "textures": len(doc.get("textures") or []),
    }


def load_mesh(path: Path):
    """One trimesh.Trimesh for the whole file, plus facts about it."""
    import trimesh

    facts: dict = {}
    src = path
    if path.suffix.lower() in NEEDS_BLENDER:
        src = _via_blender(path)
    if src.suffix.lower() in (".glb", ".gltf"):
        facts.update(gltf_facts(src))

    loaded = trimesh.load(str(src), force="scene", process=False)
    meshes = [g for g in loaded.dump() if isinstance(g, trimesh.Trimesh) and len(g.faces)]
    if not meshes:
        raise RuntimeError(f"no triangles in {path.name}")

    textured = False
    coloured = []
    for m in meshes:
        colors = None
        try:
            vis = m.visual
            if getattr(vis, "kind", None) == "texture":
                textured = True
                colors = vis.to_color().face_colors
            elif getattr(vis, "kind", None) in ("face", "vertex"):
                colors = vis.face_colors
        except Exception:
            colors = None
        if colors is None or len(colors) != len(m.faces):
            colors = np.tile(np.array([[178, 178, 186, 255]], np.uint8), (len(m.faces), 1))
        coloured.append(np.asarray(colors, dtype=np.uint8)[:, :3])

    mesh = trimesh.util.concatenate(meshes)
    face_colors = np.concatenate(coloured, axis=0)
    ext = mesh.extents
    facts.update({
        "triangles": int(len(mesh.faces)),
        "vertices": int(len(mesh.vertices)),
        "textured": textured or bool(facts.get("textures")),
        "extents": [round(float(x), 4) for x in ext],
    })
    return mesh, face_colors, facts


def _rotation(yaw_deg: float, pitch_deg: float) -> np.ndarray:
    y, p = np.radians(yaw_deg), np.radians(pitch_deg)
    ry = np.array([[np.cos(y), 0, np.sin(y)], [0, 1, 0], [-np.sin(y), 0, np.cos(y)]])
    rx = np.array([[1, 0, 0], [0, np.cos(p), -np.sin(p)], [0, np.sin(p), np.cos(p)]])
    return rx @ ry


def splat(points: np.ndarray, normals: np.ndarray, colors: np.ndarray, yaw: float,
          pitch: float, size: int = VIEW_SIZE) -> np.ndarray:
    """Orthographic point render with a depth test and simple lighting.

    Points are already centred and scaled into the unit sphere. Returns RGBA
    with a transparent background.
    """
    rot = _rotation(yaw, pitch)
    p = points @ rot.T
    n = normals @ rot.T
    margin = 0.06
    scale = (size * (1 - 2 * margin)) / 2.0
    x = np.clip(((p[:, 0] + 1) * scale + size * margin).astype(np.int32), 0, size - 1)
    y = np.clip(((1 - p[:, 1]) * scale + size * margin).astype(np.int32), 0, size - 1)
    depth = -p[:, 2]  # towards the camera is smaller

    # Nearest point per pixel: sort near to far, keep the first of each pixel.
    order = np.argsort(depth, kind="stable")
    pix = (y * size + x)[order]
    _, first = np.unique(pix, return_index=True)
    keep = order[first]

    # Two-sided Lambert from a light over the viewer's shoulder, plus ambient.
    # Meshes from the wild have inconsistent winding, so |n.l| rather than n.l.
    light = np.array([-0.35, 0.55, 0.76])
    light /= np.linalg.norm(light)
    shade = 0.32 + 0.68 * np.abs(n[keep] @ light)
    rgb = np.clip(colors[keep].astype(np.float32) * shade[:, None], 0, 255)

    img = np.zeros((size * size, 4), np.float32)
    img[pix[first], :3] = rgb
    img[pix[first], 3] = 255
    img = img.reshape(size, size, 4)
    zbuf = np.full(size * size, np.inf, np.float32)
    zbuf[pix[first]] = depth[keep]
    zbuf = zbuf.reshape(size, size)

    # Points are single pixels, so a gap in the front surface lets a point on
    # the far side through as a speck. A pixel much deeper than the nearest
    # surface around it is one of those, and is treated as a hole.
    # It is recognisable by having almost no neighbours at its own depth.
    zp = np.pad(zbuf, 1, constant_values=np.inf)
    same = np.zeros(zbuf.shape, np.int32)
    nearer = np.zeros(zbuf.shape, np.int32)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0:
                continue
            other = zp[1 + dy:1 + dy + size, 1 + dx:1 + dx + size]
            with np.errstate(invalid="ignore"):  # inf - inf where both are empty
                same += np.abs(other - zbuf) <= 0.08
            nearer += other < zbuf - 0.08
    img[np.isfinite(zbuf) & (same <= 1) & (nearer >= 3)] = 0

    # Fill pinholes: an empty pixel mostly surrounded by surface is surface.
    for _ in range(2):
        img = _fill_holes(img, size)
    return img.astype(np.uint8)


def _fill_holes(img: np.ndarray, size: int) -> np.ndarray:
    a = img[..., 3] > 0
    padded = np.pad(img, ((1, 1), (1, 1), (0, 0)))
    pa = np.pad(a, 1)
    acc = np.zeros_like(img)
    cnt = np.zeros(a.shape, np.float32)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0:
                continue
            sl = (slice(1 + dy, 1 + dy + size), slice(1 + dx, 1 + dx + size))
            acc += padded[sl] * pa[sl][..., None]
            cnt += pa[sl]
    hole = (~a) & (cnt >= 5)
    out = img.copy()
    out[hole] = acc[hole] / cnt[hole][:, None]
    return out


def render_views(path: Path, size: int = VIEW_SIZE, n_points: int = POINTS):
    """Four views of the model and a dict of facts (triangles, rigged, ...)."""
    import trimesh

    mesh, face_colors, facts = load_mesh(Path(path))
    # Centre on the bounding box and fit the bounding sphere into the frame.
    centre = mesh.bounds.mean(axis=0)
    radius = float(np.linalg.norm(mesh.vertices - centre, axis=1).max()) or 1.0

    pts, face_idx = trimesh.sample.sample_surface(mesh, n_points, seed=7)
    pts = (np.asarray(pts) - centre) / radius
    normals = mesh.face_normals[face_idx]
    colors = face_colors[face_idx]

    views = [splat(pts, normals, colors, yaw, pitch, size) for yaw, pitch in VIEWS]
    facts["low_poly"] = facts["triangles"] <= 5000
    return views, facts
