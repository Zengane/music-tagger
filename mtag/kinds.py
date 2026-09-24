"""What kind of file something is, decided by its extension.

One table, read by the scanner in the front end (through ui/gen_taxonomy.py)
and by every job here, so the two can never disagree about whether a `.webm`
is a video or a `.glb` a model.

The kinds are deliberately few. A kind decides which analysis a file gets and
which filter it shows up under; anything finer — a PNG sequence versus a
still, a stock photo versus a meme — is a tag, decided by looking.
"""

from __future__ import annotations

from pathlib import Path

from .taxonomy import AUDIO_EXTS

AUDIO = "audio"
IMAGE = "image"
VIDEO = "video"
MODEL = "model"      # 3D
DOCUMENT = "document"

KINDS = (AUDIO, IMAGE, VIDEO, MODEL, DOCUMENT)

EXTENSIONS: dict[str, tuple[str, ...]] = {
    # The audio list is the one the tagger was built and trained on.
    AUDIO: tuple(sorted(AUDIO_EXTS)),
    # Everything Pillow opens, plus the vector and layered formats that are
    # rasterised first (see mtag/media/decode.py for how each is read).
    IMAGE: (".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tif", ".tiff", ".tga",
            ".psd", ".heic", ".heif", ".avif", ".jxl", ".exr", ".hdr", ".dds", ".qoi",
            ".svg", ".ai", ".eps"),
    VIDEO: (".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi", ".wmv", ".mpg", ".mpeg",
            ".mts", ".m2ts", ".mxf", ".flv", ".3gp", ".ogv", ".prores"),
    MODEL: (".glb", ".gltf", ".obj", ".stl", ".ply", ".off", ".3mf", ".dae", ".fbx",
            ".blend", ".usd", ".usda", ".usdc", ".usdz", ".abc"),
    DOCUMENT: (".pdf", ".docx", ".txt", ".md", ".markdown", ".rtf", ".odt", ".srt",
               ".vtt", ".fountain"),
}

_BY_EXT = {ext: kind for kind, exts in EXTENSIONS.items() for ext in exts}


def kind_of(path) -> str | None:
    """The kind of `path`, or None for a file this app does not handle."""
    return _BY_EXT.get(Path(path).suffix.lower())


def is_visual(kind: str | None) -> bool:
    """Kinds that are analysed by looking at pictures of them."""
    return kind in (IMAGE, VIDEO, MODEL)
