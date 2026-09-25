"""MagicaVoxel models (.vox) to a mesh.

The format is a RIFF-like list of chunks: SIZE gives a model's dimensions,
XYZI its voxels as (x, y, z, colour index), RGBA the 256-colour palette. Each
voxel face that touches empty space becomes two triangles, coloured from the
palette. Only the first model in a file is used, which is what nearly every
.vox is.
"""

from __future__ import annotations

import struct
from pathlib import Path

import numpy as np

# MagicaVoxel's default palette is used when a file carries none. Rather than
# ship its 256 entries, a neutral ramp is used: files without a palette are
# rare and this keeps the shape readable.
_FALLBACK = np.concatenate([np.stack([np.linspace(60, 230, 256)] * 3, axis=1), np.full((256, 1), 255)], axis=1)

_DIRS = (
    ((1, 0, 0), ((1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1))),
    ((-1, 0, 0), ((0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0))),
    ((0, 1, 0), ((0, 1, 0), (0, 1, 1), (1, 1, 1), (1, 1, 0))),
    ((0, -1, 0), ((0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1))),
    ((0, 0, 1), ((0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1))),
    ((0, 0, -1), ((0, 0, 0), (0, 1, 0), (1, 1, 0), (1, 0, 0))),
)


def _read(path: Path):
    raw = Path(path).read_bytes()
    if raw[:4] != b"VOX ":
        raise RuntimeError("not a MagicaVoxel file")
    size = None
    voxels = None
    palette = None
    i = 8
    while i + 12 <= len(raw):
        cid = raw[i:i + 4]
        n, _children = struct.unpack_from("<ii", raw, i + 4)
        body = raw[i + 12:i + 12 + n]
        if cid == b"MAIN":
            i += 12  # step inside
            continue
        if cid == b"SIZE" and size is None:
            size = struct.unpack_from("<iii", body, 0)
        elif cid == b"XYZI" and voxels is None:
            count = struct.unpack_from("<i", body, 0)[0]
            voxels = np.frombuffer(body, dtype=np.uint8, count=count * 4, offset=4).reshape(-1, 4)
        elif cid == b"RGBA" and palette is None:
            palette = np.frombuffer(body, dtype=np.uint8, count=256 * 4).reshape(256, 4)
        i += 12 + n
    if size is None or voxels is None:
        raise RuntimeError("no voxels in the file")
    if palette is None:
        palette = _FALLBACK.astype(np.uint8)
    else:
        # Colour index i is stored at palette[i - 1].
        palette = np.concatenate([palette[-1:], palette[:-1]], axis=0)
    return size, voxels, palette


def to_mesh(path: Path):
    import trimesh

    size, voxels, palette = _read(path)
    occupied = np.zeros((size[0] + 2, size[1] + 2, size[2] + 2), dtype=bool)
    occupied[voxels[:, 0].astype(int) + 1, voxels[:, 1].astype(int) + 1, voxels[:, 2].astype(int) + 1] = True
    verts, faces, colours = [], [], []
    cells = voxels.astype(np.int64)
    for (dx, dy, dz), quad in _DIRS:
        for x, y, z, c in cells:
            if occupied[x + 1 + dx, y + 1 + dy, z + 1 + dz]:
                continue
            base = len(verts)
            # MagicaVoxel is z-up; glTF and the viewer are y-up.
            for qx, qy, qz in quad:
                verts.append((x + qx, z + qz, -(y + qy)))
            faces.append((base, base + 1, base + 2))
            faces.append((base, base + 2, base + 3))
            colours.extend([palette[c]] * 2)
    if not faces:
        raise RuntimeError("no visible voxels")
    v = np.asarray(verts, dtype=float)
    v -= v.mean(axis=0)
    mesh = trimesh.Trimesh(vertices=v / 16.0, faces=np.asarray(faces), process=False)
    mesh.visual.face_colors = np.asarray(colours, dtype=np.uint8)
    return mesh


def to_glb(path: Path, out: Path) -> Path:
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(to_mesh(path).export(file_type="glb"))
    return out
