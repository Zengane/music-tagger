"""Blockbench models (.bbmodel) to glTF.

A .bbmodel is JSON: cubes ("elements" with `from`, `to`, a pivot and a
rotation, and a UV rectangle per face), free-form meshes, a tree of groups
that rotate their children about a pivot, and the textures as base64 PNGs.
Nothing reads it but Blockbench, so this builds the triangles itself and hands
them to trimesh, which writes a GLB the viewer and the thumbnailer already
know how to open.

Coordinates are Blockbench's: x east, y up, z south, one unit a texture pixel.
Face UVs follow the Minecraft block-model convention the format comes from.
"""

from __future__ import annotations

import base64
import io
import json
import math
from pathlib import Path

import numpy as np

# For each face: its four corners as (x, y, z) picks from (from, to), in the
# order top-left, top-right, bottom-right, bottom-left as seen from outside,
# which is the order the face's UV rectangle is laid over them.
# 0 picks `from`, 1 picks `to`, per axis.
_FACE_CORNERS = {
    "north": ((1, 1, 0), (0, 1, 0), (0, 0, 0), (1, 0, 0)),
    "south": ((0, 1, 1), (1, 1, 1), (1, 0, 1), (0, 0, 1)),
    "east":  ((1, 1, 1), (1, 1, 0), (1, 0, 0), (1, 0, 1)),
    "west":  ((0, 1, 0), (0, 1, 1), (0, 0, 1), (0, 0, 0)),
    "up":    ((0, 1, 0), (1, 1, 0), (1, 1, 1), (0, 1, 1)),
    "down":  ((0, 0, 1), (1, 0, 1), (1, 0, 0), (0, 0, 0)),
}


def _rotation_matrix(rot_deg) -> np.ndarray:
    """Blockbench rotates X, then Y, then Z (three.js order 'ZYX')."""
    rx, ry, rz = (math.radians(float(a)) for a in rot_deg)
    cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
    mx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    my = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    mz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    return mz @ my @ mx


def _pivot_transform(origin, rotation) -> np.ndarray:
    """4x4: rotate about `origin`."""
    m = np.eye(4)
    o = np.asarray(origin if origin is not None else (0, 0, 0), dtype=float)
    r = _rotation_matrix(_rotation_of(rotation))
    m[:3, :3] = r
    m[:3, 3] = o - r @ o
    return m


def _rotation_of(rotation) -> tuple[float, float, float]:
    """Newer files store [x, y, z]; Java block models an angle about one axis."""
    if rotation is None:
        return (0.0, 0.0, 0.0)
    if isinstance(rotation, dict):
        angle = float(rotation.get("angle", 0))
        axis = rotation.get("axis", "y")
        return tuple(angle if a == axis else 0.0 for a in "xyz")  # type: ignore[return-value]
    if isinstance(rotation, (list, tuple)) and len(rotation) == 3:
        return tuple(float(v) for v in rotation)  # type: ignore[return-value]
    return (0.0, 0.0, 0.0)


def _load_textures(doc: dict, base: Path):
    from PIL import Image

    out = []
    for tex in doc.get("textures") or []:
        img = None
        src = tex.get("source") or ""
        try:
            if src.startswith("data:"):
                img = Image.open(io.BytesIO(base64.b64decode(src.split(",", 1)[1])))
            else:
                for key in ("path", "relative_path"):
                    p = tex.get(key)
                    if p and (base / p).exists():
                        img = Image.open(base / p)
                        break
                    if p and Path(p).exists():
                        img = Image.open(p)
                        break
        except Exception:
            img = None
        if img is not None:
            img = img.convert("RGBA")
        out.append({"image": img, "uv_w": float(tex.get("uv_width") or 0), "uv_h": float(tex.get("uv_height") or 0)})
    return out


class _Builder:
    """Triangles collected per texture, with their UVs."""

    def __init__(self, textures, resolution):
        self.textures = textures
        self.res = resolution
        self.parts: dict[int, dict[str, list]] = {}

    def uv_scale(self, tex_index: int) -> tuple[float, float]:
        if 0 <= tex_index < len(self.textures):
            t = self.textures[tex_index]
            if t["uv_w"] and t["uv_h"]:
                return t["uv_w"], t["uv_h"]
        return self.res

    def add_polygon(self, tex_index: int, points: np.ndarray, uvs: list[tuple[float, float]]):
        part = self.parts.setdefault(tex_index, {"v": [], "uv": [], "f": []})
        w, h = self.uv_scale(tex_index)
        start = len(part["v"])
        for p, (u, v) in zip(points, uvs):
            part["v"].append(p)
            # trimesh keeps UVs with the origin at the bottom; Blockbench's
            # is at the top, like the image.
            part["uv"].append((u / w, 1.0 - v / h))
        for k in range(1, len(points) - 1):
            part["f"].append((start, start + k, start + k + 1))


def _add_cube(b: _Builder, el: dict, transform: np.ndarray):
    lo = np.asarray(el.get("from", (0, 0, 0)), dtype=float)
    hi = np.asarray(el.get("to", (0, 0, 0)), dtype=float)
    inflate = float(el.get("inflate") or 0)
    lo, hi = lo - inflate, hi + inflate
    local = _pivot_transform(el.get("origin"), el.get("rotation")) if el.get("rotation") is not None else np.eye(4)
    m = transform @ local
    for name, face in (el.get("faces") or {}).items():
        if name not in _FACE_CORNERS or not isinstance(face, dict):
            continue
        tex = face.get("texture")
        if tex is None or tex is False:
            continue
        tex = int(tex)
        uv = face.get("uv") or (0, 0, 0, 0)
        u1, v1, u2, v2 = (float(x) for x in uv)
        corners_uv = [(u1, v1), (u2, v1), (u2, v2), (u1, v2)]
        turns = int(round(float(face.get("rotation") or 0) / 90)) % 4
        corners_uv = corners_uv[-turns:] + corners_uv[:-turns] if turns else corners_uv
        pts = []
        for pick in _FACE_CORNERS[name]:
            p = np.array([hi[i] if pick[i] else lo[i] for i in range(3)] + [1.0])
            pts.append((m @ p)[:3])
        # The corners run clockwise as seen from outside; triangles want them
        # anticlockwise to face outwards.
        b.add_polygon(tex, np.asarray(pts[::-1]), corners_uv[::-1])


def _add_mesh(b: _Builder, el: dict, transform: np.ndarray):
    verts = {k: np.asarray(v, dtype=float) for k, v in (el.get("vertices") or {}).items()}
    local = _pivot_transform(el.get("origin"), el.get("rotation"))
    m = transform @ local
    for face in (el.get("faces") or {}).values():
        ids = [i for i in face.get("vertices") or [] if i in verts]
        tex = face.get("texture")
        if len(ids) < 3 or tex is None or tex is False:
            continue
        pts = np.asarray([verts[i] for i in ids])
        if len(ids) == 4:
            # Blockbench does not keep a quad's corners in winding order.
            # Put them round the centre, in the face's own plane.
            c = pts.mean(axis=0)
            n = np.cross(pts[1] - pts[0], pts[2] - pts[0])
            if np.linalg.norm(n) < 1e-9:
                n = np.cross(pts[2] - pts[0], pts[3] - pts[0])
            n = n / max(np.linalg.norm(n), 1e-9)
            a = pts[0] - c
            a = a / max(np.linalg.norm(a), 1e-9)
            bb = np.cross(n, a)
            order = np.argsort([math.atan2(np.dot(p - c, bb), np.dot(p - c, a)) for p in pts])
            ids = [ids[i] for i in order]
            pts = pts[order]
        uv_map = face.get("uv") or {}
        uvs = [tuple(uv_map.get(i, (0, 0))) for i in ids]
        world = [(m @ np.append(p, 1.0))[:3] for p in pts]
        b.add_polygon(int(tex), np.asarray(world), uvs)


def _walk(b: _Builder, node, elements: dict, transform: np.ndarray, seen: set):
    if isinstance(node, str):
        el = elements.get(node)
        if el is None or node in seen or el.get("visibility") is False:
            return
        seen.add(node)
        if el.get("type", "cube") == "mesh":
            _add_mesh(b, el, transform)
        elif el.get("type", "cube") == "cube":
            _add_cube(b, el, transform)
        return
    if isinstance(node, dict):
        if node.get("visibility") is False:
            return
        t = transform
        if node.get("rotation") is not None:
            t = transform @ _pivot_transform(node.get("origin"), node.get("rotation"))
        for child in node.get("children") or []:
            _walk(b, child, elements, t, seen)


def to_scene(path: Path):
    """A trimesh.Scene for a .bbmodel, one mesh per texture."""
    import trimesh

    doc = json.loads(Path(path).read_text(encoding="utf-8"))
    res = doc.get("resolution") or {}
    resolution = (float(res.get("width") or 16), float(res.get("height") or 16))
    textures = _load_textures(doc, Path(path).parent)
    b = _Builder(textures, resolution)

    elements = {}
    for i, el in enumerate(doc.get("elements") or []):
        elements[el.get("uuid") or f"_{i}"] = el
    seen: set = set()
    for node in doc.get("outliner") or []:
        _walk(b, node, elements, np.eye(4), seen)
    # Elements the outliner does not mention (older files have no outliner).
    for key in elements:
        if key not in seen:
            _walk(b, key, elements, np.eye(4), seen)

    scene = trimesh.Scene()
    for tex_index, part in b.parts.items():
        if not part["f"]:
            continue
        # Blockbench units are pixels; sixteen to the block, one block to a
        # metre.
        mesh = trimesh.Trimesh(vertices=np.asarray(part["v"]) / 16.0, faces=np.asarray(part["f"]), process=False)
        image = textures[tex_index]["image"] if 0 <= tex_index < len(textures) else None
        if image is not None:
            material = trimesh.visual.material.PBRMaterial(baseColorTexture=image, metallicFactor=0.0,
                                                           roughnessFactor=1.0, doubleSided=True,
                                                           alphaMode="MASK", alphaCutoff=0.1)
            mesh.visual = trimesh.visual.TextureVisuals(uv=np.asarray(part["uv"]), material=material)
        scene.add_geometry(mesh, node_name=f"texture_{tex_index}")
    if not scene.geometry:
        raise RuntimeError(f"no visible faces in {Path(path).name}")
    return scene


def to_glb(path: Path, out: Path) -> Path:
    scene = to_scene(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(scene.export(file_type="glb"))
    return out
