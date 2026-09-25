r"""Natural-language search, as a child process that stays up while it is used.

Unlike the tagging jobs this one does not exit after one answer: loading the
text towers takes seconds and a search has to answer as you type. It reads one
JSON request per line on stdin and answers on stdout:

    -> {"id": 3, "query": "muzzle flash on black", "limit": 500}
    <- {"event": "hits", "id": 3, "hits": [[12, 4.31], [907, 3.9], ...]}

A hit is [index into the path list, score]. Other requests:

    -> {"reload": true}      re-read the caches (after an analysis run)
    -> {"quit": true}

It exits when stdin closes, which is what happens when the app does, and after
IDLE_MINUTES with no request, to give the memory back.

    venv/bin/python search_server.py --paths-from <file>
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from mtag import console  # noqa: E402

IDLE_MINUTES = 20


def emit(**payload) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


class _Lazy:
    """Loads a text tower the first time a query needs it."""

    def __init__(self, loader, label):
        self.loader, self.label, self.enc, self.failed = loader, label, None, False

    def embed_query(self, texts):
        if self.failed:
            return None
        if self.enc is None:
            try:
                emit(event="loading", detail=f"loading {self.label}")
                self.enc = self.loader()
            except Exception as e:
                self.failed = True
                traceback.print_exc(file=sys.stderr)
                emit(event="warning", message=f"{self.label} unavailable: {e}")
                return None
        return self.enc(texts)


def encoders_for(build) -> tuple[dict, dict]:
    """(space name -> is audio mean+std, space name -> lazy query encoder)."""
    from mtag.media import models as MD

    spaces, enc = {}, {}

    s = MD.space_name(build.siglip)
    spaces[s] = False

    def siglip():
        m = MD.Siglip(build.siglip).load()
        # Plain words and a photo-style phrasing, averaged: SigLIP was trained
        # on captions, and a bare two-word query is not one.
        def f(texts):
            import numpy as np

            a = m.embed_texts(texts)
            b = m.embed_texts([f"a photo of {t}" for t in texts])
            v = a + b
            return v / np.linalg.norm(v, axis=1, keepdims=True)
        return f
    enc[s] = _Lazy(siglip, "the image search model")

    t = MD.space_name(build.text)
    spaces[t] = False

    def e5():
        m = MD.TextEmbedder(build.text).load()
        return lambda texts: m.embed(texts, kind="query")
    enc[t] = _Lazy(e5, "the text search model")

    # Audio. The music cache is written by the tagger's CLAP part, the effects
    # cache by the effects map; both are mean+std pooled.
    spaces["clap-music"] = True

    def clap_music():
        from mtag.encoders import ClapMusicEncoder

        m = ClapMusicEncoder()
        m.load()
        return m.embed_text
    enc["clap-music"] = _Lazy(clap_music, "the music search model")

    # The profile's sound model (PE-AV above the fast profile). Its vectors
    # are written by the effects job and the effects map.
    from mtag.encoders import BY_MODEL_ID

    at_cls = BY_MODEL_ID.get(build.audio_text)
    if at_cls is not None and at_cls.name not in ("clap-sfx-v1", "clap-music"):
        spaces[at_cls.name] = True

        def audio_text(cls=at_cls):
            m = cls()
            m.load()
            return m.embed_text
        enc[at_cls.name] = _Lazy(audio_text, "the sound search model")

    spaces["clap-sfx-v1"] = True

    def clap_sfx():
        from mtag.encoders import ClapMusicEncoder

        class EffectsEncoder(ClapMusicEncoder):
            MODEL_ID = "laion/clap-htsat-unfused"

        m = EffectsEncoder()
        m.load()
        return m.embed_text
    enc["clap-sfx-v1"] = _Lazy(clap_sfx, "the sound search model")
    return spaces, enc


def main() -> int:
    console.init()
    # The app writes UTF-8. On Windows stdin would otherwise be read in the
    # ANSI code page, and "café" or "ブルー" would arrive as mojibake.
    try:
        sys.stdin.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--paths-from", required=True)
    args = ap.parse_args()

    from mtag.media import models as MD
    from mtag.semantic import Index

    paths = [l.strip() for l in Path(args.paths_from).read_text(encoding="utf-8").splitlines() if l.strip()]
    build = MD.current_build()
    spaces, encoders = encoders_for(build)

    def build_index():
        # Media results from any profile are read for words (captions, OCR),
        # the current one first; vectors only from the current models.
        return Index(paths, spaces, media_builds=[build.name, "fast", "balanced", "best", "small", "large", "measured"])

    index = build_index()
    emit(event="ready", files=len(paths), spaces=index.counts())

    # stdin is read on a thread so the idle timeout works on every platform
    # (select() does not take pipes on Windows).
    lines: list[str] = []
    cond = threading.Condition()
    closed = threading.Event()

    def reader():
        for line in sys.stdin:
            with cond:
                lines.append(line)
                cond.notify()
        closed.set()
        with cond:
            cond.notify()

    threading.Thread(target=reader, daemon=True).start()
    last = time.monotonic()
    while True:
        with cond:
            if not lines and not closed.is_set():
                cond.wait(timeout=30)
            batch, lines[:] = lines[:], []
        if not batch:
            if closed.is_set():
                return 0
            if time.monotonic() - last > IDLE_MINUTES * 60:
                emit(event="idle-exit")
                return 0
            continue
        last = time.monotonic()
        # Only the newest query matters: while typing, the earlier ones are
        # already out of date.
        requests = []
        for raw in batch:
            try:
                requests.append(json.loads(raw))
            except json.JSONDecodeError:
                continue
        queries = [r for r in requests if "query" in r]
        for r in requests:
            if r.get("quit"):
                return 0
            if r.get("reload"):
                index = build_index()
                emit(event="ready", files=len(paths), spaces=index.counts())
        if queries:
            r = queries[-1]
            try:
                hits = index.search(str(r["query"]), encoders, int(r.get("limit", 500)))
                emit(event="hits", id=r.get("id", 0), query=r["query"], hits=hits)
            except Exception as e:
                traceback.print_exc(file=sys.stderr)
                emit(event="error", id=r.get("id", 0), message=str(e))


if __name__ == "__main__":
    sys.exit(main())
