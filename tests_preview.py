"""Checks for preview_job.py and the 3D converters behind it.

    python tests_preview.py

Every fixture is built here, so the checks need no files from anywhere else.
"""

from __future__ import annotations

import base64
import io
import json
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

failures = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global failures
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}" + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures += 1


def png_b64(colour, size=16) -> str:
    from PIL import Image

    img = Image.new("RGBA", (size, size), colour)
    # A different colour in the top-left quarter, so UVs have something to hit.
    for x in range(size // 2):
        for y in range(size // 2):
            img.putpixel((x, y), (255, 255, 255, 255))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


def make_bbmodel(path: Path) -> None:
    faces = {name: {"uv": [0, 0, 8, 8], "texture": 0} for name in ("north", "south", "east", "west", "up", "down")}
    faces["down"] = {"uv": [0, 0, 8, 8], "texture": None}  # hidden face
    doc = {
        "meta": {"format_version": "4.10", "model_format": "free"},
        "resolution": {"width": 16, "height": 16},
        "elements": [
            {"uuid": "a", "type": "cube", "from": [-4, 0, -4], "to": [4, 8, 4], "origin": [0, 0, 0], "faces": faces},
            {"uuid": "b", "type": "cube", "from": [-1, 8, -1], "to": [1, 16, 1], "origin": [0, 8, 0],
             "rotation": [0, 0, 45], "faces": {n: {"uv": [8, 8, 10, 16], "texture": 0} for n in
                                               ("north", "south", "east", "west", "up", "down")}},
            {"uuid": "c", "type": "mesh", "origin": [0, 0, 0],
             "vertices": {"p": [0, 20, 0], "q": [4, 20, 0], "r": [4, 24, 0], "s": [0, 24, 0]},
             "faces": {"f": {"vertices": ["p", "r", "q", "s"], "uv": {"p": [0, 0], "q": [4, 0], "r": [4, 4], "s": [0, 4]},
                             "texture": 0}}},
        ],
        "outliner": [{"uuid": "g", "name": "body", "origin": [0, 0, 0], "rotation": [0, 90, 0],
                      "children": ["a", "b"]}, "c"],
        "textures": [{"name": "skin.png", "source": png_b64((200, 40, 40, 255))}],
    }
    path.write_text(json.dumps(doc), encoding="utf-8")


def make_vox(path: Path) -> None:
    voxels = [(x, y, z, 1 + (x + y + z) % 3) for x in range(3) for y in range(3) for z in range(2)]
    xyzi = struct.pack("<i", len(voxels)) + b"".join(struct.pack("<BBBB", *v) for v in voxels)
    size = struct.pack("<iii", 3, 3, 2)
    palette = bytes([c for i in range(256) for c in (i, 255 - i, 128, 255)])

    def chunk(cid, body):
        return cid + struct.pack("<ii", len(body), 0) + body

    children = chunk(b"SIZE", size) + chunk(b"XYZI", xyzi) + chunk(b"RGBA", palette)
    main = b"MAIN" + struct.pack("<ii", 0, len(children)) + children
    path.write_bytes(b"VOX " + struct.pack("<i", 150) + main)


def make_pdf(path: Path) -> None:
    from PIL import Image

    pages = [Image.new("RGB", (400, 560), c) for c in ((250, 250, 250), (230, 240, 255))]
    pages[0].save(path, save_all=True, append_images=pages[1:])


def make_docx(path: Path) -> None:
    import docx

    d = docx.Document()
    d.add_paragraph("INT. WAREHOUSE - NIGHT")
    d.add_paragraph("A muzzle flash lights the room.")
    d.save(str(path))


def run_job(*args) -> dict:
    out = subprocess.run([sys.executable, str(HERE / "preview_job.py"), *map(str, args)],
                         capture_output=True, text=True, cwd=HERE, timeout=120)
    lines = [l for l in out.stdout.splitlines() if l.startswith("{")]
    return json.loads(lines[-1]) if lines else {"ok": False, "error": out.stderr[-400:]}


def main() -> int:
    import trimesh

    tmp = Path(tempfile.mkdtemp(prefix="mt-preview-"))

    print("\nblockbench")
    bb = tmp / "character.bbmodel"
    make_bbmodel(bb)
    from mtag.media import bbmodel

    scene = bbmodel.to_scene(bb)
    geoms = list(scene.geometry.values())
    tris = sum(len(g.faces) for g in geoms)
    # Cube a: 5 visible faces; cube b: 6; the mesh quad: 1. Two triangles each.
    check("every visible face becomes two triangles", tris == (5 + 6 + 1) * 2, f"{tris} triangles")
    mesh = trimesh.util.concatenate(geoms)
    lo, hi = mesh.bounds
    check("the group's rotation turns the arm about its pivot",
          abs(hi[1] - 1.5) < 1e-6 and hi[0] < 1.0, f"bounds {lo} {hi}")
    # A closed cube, alone: its signed volume is positive only if every face
    # is wound to point outwards.
    solid = tmp / "solid.bbmodel"
    solid.write_text(json.dumps({"resolution": {"width": 16, "height": 16}, "elements": [
        {"from": [0, 0, 0], "to": [16, 16, 16], "faces": {n: {"uv": [0, 0, 16, 16], "texture": 0} for n in
                                                           ("north", "south", "east", "west", "up", "down")}}],
        "textures": [{"source": png_b64((10, 200, 10, 255))}]}), encoding="utf-8")
    cube = trimesh.util.concatenate(list(bbmodel.to_scene(solid).geometry.values()))
    check("Blockbench faces point outwards", abs(cube.volume - 1.0) < 1e-9, f"volume {cube.volume}")
    uv = geoms[0].visual.uv
    check("UVs are in the texture's 0..1 range", float(uv.min()) >= 0 and float(uv.max()) <= 1.0001)
    out = tmp / "bb.glb"
    result = run_job("mesh", bb, out)
    check("preview_job converts a .bbmodel to GLB", result.get("ok") and out.exists(), json.dumps(result))
    if out.exists():
        back = trimesh.load(str(out), force="scene")
        check("the GLB keeps its texture",
              any(getattr(g.visual, "kind", None) == "texture" for g in back.geometry.values()))

    print("\nmagicavoxel")
    vox = tmp / "crate.vox"
    make_vox(vox)
    from mtag.media import voxel

    vm = voxel.to_mesh(vox)
    # A 3x3x2 block has 2*(9+6+6) = 42 outside faces.
    check("only faces that touch air are kept", len(vm.faces) == 42 * 2, f"{len(vm.faces)} triangles")
    check("faces point outwards", abs(vm.volume - 18 / 16 ** 3) < 1e-9, f"volume {vm.volume:.6f}")
    result = run_job("mesh", vox, tmp / "vox.glb")
    check("preview_job converts a .vox", result.get("ok"), json.dumps(result))

    print("\nother 3D")
    stl = tmp / "box.stl"
    trimesh.creation.box((1, 2, 3)).export(str(stl))
    result = run_job("mesh", stl, tmp / "stl.glb")
    check("an STL becomes a GLB", result.get("ok") and (tmp / "stl.glb").exists(), json.dumps(result))
    c4d = tmp / "scene.c4d"
    c4d.write_bytes(b"QC4DC4D6" + bytes(64))
    result = run_job("mesh", c4d, tmp / "c4d.glb")
    check("a Cinema 4D file says what to do instead of failing silently",
          not result.get("ok") and "Cinema 4D" in result.get("error", ""), json.dumps(result))

    from mtag.media import render3d

    m, colours, facts = render3d.load_mesh(bb)
    check("the thumbnailer reads a .bbmodel too", facts["triangles"] == 24 and len(colours) == 24,
          f"{facts}")

    print("\ndocuments")
    pdf = tmp / "brief.pdf"
    make_pdf(pdf)
    result = run_job("pages", pdf, tmp / "pages", 10, 300)
    written = sorted((tmp / "pages").glob("page-*.png"))
    check("every PDF page is drawn", result.get("ok") and len(written) == 2, json.dumps(result))
    info = json.loads((tmp / "pages" / "pages.json").read_text()) if (tmp / "pages" / "pages.json").exists() else {}
    check("the page count is recorded", info.get("total") == 2)

    doc = tmp / "script.docx"
    make_docx(doc)
    result = run_job("text", doc, tmp / "script.txt")
    body = (tmp / "script.txt").read_text() if (tmp / "script.txt").exists() else ""
    check("a .docx is read as text", result.get("ok") and "muzzle flash" in body, body[:80])

    print()
    print("all preview checks passed" if failures == 0 else f"{failures} preview checks failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
