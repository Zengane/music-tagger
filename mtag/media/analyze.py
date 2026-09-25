"""Analysing images, video, 3D models and documents, a batch at a time.

For each file:

  1. decode it into a few frames (or text)                        decode.py
  2. measure what needs no model: keying, alpha, colour, flashes,
     loops, cuts, orientation, frame rate                         measure.py
  3. SigLIP: one vector per frame, zero-shot scores per tag,
     pooled per group across frames                               vocab.py
  4. Florence-2: a caption, and the text in the picture (OCR)
  5. E5: one vector for what the file says or is described as, and
     document categories

Results are cached under the file's key, so a second run over the same files
reads them back instead of running any model, and the search server reads the
vectors from the same place.

The models are passed in, so tests can run the whole pipeline with stand-ins
and no downloads.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .. import kinds as K
from ..dataset import CACHE_ROOT, _key
from . import decode as D
from . import measure as M
from . import vocab as V

# A result written by an older analyser is re-run rather than trusted.
RESULT_VERSION = 1


def ui_key(path) -> str:
    """The front end's cache key for a file: FNV-1a over the path as given,
    then size and mtime in nanoseconds, little-endian. Mirrors hash_key in
    ui/audio.odin, so thumbnails written here are found there by name."""
    # Hashed exactly as the app sent it: Path() would tidy the separators and
    # the app, which hashes its own string, would not find the thumbnail.
    st = Path(path).stat()
    h = 0xCBF29CE484222325
    data = str(path).encode("utf-8") + int(st.st_size).to_bytes(8, "little", signed=True) \
        + int(st.st_mtime_ns).to_bytes(8, "little", signed=True)
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


def thumb_path(path) -> Path:
    return CACHE_ROOT / "thumbs" / f"{ui_key(path)}.png"


@dataclass
class Models:
    """Whatever is available. Any of them may be None; the analysis then does
    what it can without it and says so in the result."""

    siglip: object | None = None
    florence: object | None = None
    text: object | None = None
    build: str = ""


@dataclass
class Result:
    path: str
    kind: str
    scores: dict[str, tuple[float, float, bool]] = field(default_factory=dict)  # tag -> (score, threshold, suggest_only)
    caption: str = ""
    ocr: str = ""
    text_excerpt: str = ""
    metrics: dict = field(default_factory=dict)
    thumb: str = ""
    visual_vec: np.ndarray | None = None
    text_vec: np.ndarray | None = None
    notes: list[str] = field(default_factory=list)

    def selected(self) -> list[str]:
        ranked = sorted(self.scores.items(), key=lambda kv: -kv[1][0])
        return [t for t, (s, th, only) in ranked if s >= th and not only]

    def to_event(self) -> dict:
        ranked = sorted(self.scores.items(), key=lambda kv: -kv[1][0])
        return {
            "event": "result",
            "path": self.path,
            "kind": self.kind,
            "selected": self.selected(),
            "scores": [{"tag": t, "score": round(float(s), 4), "threshold": round(float(th), 4),
                        "zero_shot": True, "suggest_only": bool(only)} for t, (s, th, only) in ranked],
            "caption": self.caption,
            "ocr": self.ocr,
            "excerpt": self.text_excerpt[:400],
            "thumb": self.thumb,
            "metrics": _jsonable(self.metrics),
            "notes": self.notes,
            "game": "",
        }


def _jsonable(x):
    if isinstance(x, dict):
        return {str(k): _jsonable(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [_jsonable(v) for v in x]
    if isinstance(x, (np.floating,)):
        return float(x)
    if isinstance(x, (np.integer,)):
        return int(x)
    if isinstance(x, np.ndarray):
        return None
    return x


# ── caches ──────────────────────────────────────────────────────────────────

def _result_dir(build: str) -> Path:
    return CACHE_ROOT / f"media-{build or 'measured'}"


def _vec_dir(space: str) -> Path:
    return CACHE_ROOT / space


def load_cached(path: Path, models: Models, raw: str | None = None) -> Result | None:
    p = _result_dir(models.build) / f"{_key(path)}.json"
    if not p.exists():
        return None
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if doc.get("version") != RESULT_VERSION:
        return None
    # A result made without a model that is now available is not good enough.
    have = doc.get("models", {})
    for name in ("siglip", "florence", "text"):
        if getattr(models, name) is not None and not have.get(name):
            return None
    r = Result(path=raw if raw is not None else str(path), kind=doc["kind"], caption=doc.get("caption", ""), ocr=doc.get("ocr", ""),
               text_excerpt=doc.get("excerpt", ""), metrics=doc.get("metrics", {}),
               thumb=doc.get("thumb", ""), notes=doc.get("notes", []))
    r.scores = {t: tuple(v) for t, v in doc.get("scores", {}).items()}
    if r.thumb and not Path(r.thumb).exists():
        r.thumb = ""
    return r


def store(result: Result, path: Path, models: Models) -> None:
    key = _key(path)
    d = _result_dir(models.build)
    d.mkdir(parents=True, exist_ok=True)
    doc = {
        "version": RESULT_VERSION, "kind": result.kind, "path": result.path,
        "scores": {t: list(v) for t, v in result.scores.items()},
        "caption": result.caption, "ocr": result.ocr, "excerpt": result.text_excerpt,
        "metrics": _jsonable(result.metrics), "thumb": result.thumb, "notes": result.notes,
        "models": {"siglip": models.siglip is not None, "florence": models.florence is not None,
                   "text": models.text is not None},
    }
    (d / f"{key}.json").write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    if result.visual_vec is not None and models.siglip is not None:
        vd = _vec_dir(models.siglip.space)
        vd.mkdir(parents=True, exist_ok=True)
        np.save(vd / f"{key}.npy", result.visual_vec.astype(np.float32))
    if result.text_vec is not None and models.text is not None:
        td = _vec_dir(models.text.space)
        td.mkdir(parents=True, exist_ok=True)
        np.save(td / f"{key}.npy", result.text_vec.astype(np.float32))


# ── the vocabulary, embedded once per job ───────────────────────────────────

@dataclass
class PromptBank:
    groups: list
    tags: list[tuple[int, str]]          # (group index, tag) per row of `tag_rows`
    prompt_vecs: np.ndarray | None       # (n_prompts, d)
    prompt_tag: np.ndarray               # (n_prompts,) index into `tags`
    doc_labels: list[str]
    doc_vecs: np.ndarray | None


def build_prompts(models: Models) -> PromptBank:
    groups = V.load()
    tags, prompts, owner = [], [], []
    for gi, g in enumerate(groups):
        for tag, phrases in g.tags.items():
            ti = len(tags)
            tags.append((gi, tag))
            for ph in phrases:
                prompts.append(ph)
                owner.append(ti)
    vecs = models.siglip.embed_texts(prompts) if models.siglip is not None and prompts else None
    labels = list(V.DOCUMENT_TAGS)
    doc_vecs = None
    if models.text is not None:
        doc_vecs = models.text.embed([V.DOCUMENT_TAGS[l] for l in labels], kind="query")
    return PromptBank(groups, tags, vecs, np.array(owner, dtype=np.int64), labels, doc_vecs)


def zero_shot(frame_vecs: np.ndarray, kind: str, bank: PromptBank, siglip) -> dict[str, tuple[float, float, bool]]:
    """Per-tag scores for one file from its frame vectors."""
    if bank.prompt_vecs is None or len(frame_vecs) == 0:
        return {}
    probs = siglip.probabilities(frame_vecs, bank.prompt_vecs)   # (frames, prompts)
    # Best phrasing per tag, per frame.
    per_tag = np.zeros((probs.shape[0], len(bank.tags)), np.float32)
    np.maximum.at(per_tag.T, bank.prompt_tag, probs.T)
    out = {}
    for ti, (gi, tag) in enumerate(bank.tags):
        g = bank.groups[gi]
        if kind not in g.kinds:
            continue
        col = per_tag[:, ti]
        if g.pool == "max":
            score = float(col.max())
        else:
            # The better half of the frames: a location that holds for most of
            # the clip should not be sunk by a cutaway.
            k = max(1, (len(col) + 1) // 2)
            score = float(np.sort(col)[-k:].mean())
        th = g.overrides.get(tag, g.threshold)
        prev = out.get(tag)
        if prev is None or score > prev[0]:
            out[tag] = (score, th, g.suggest_only)
    return out


# ── OCR clean-up ────────────────────────────────────────────────────────────

def clean_ocr(texts: list[str]) -> str:
    """Join OCR from several frames, dropping repeats and noise."""
    seen, lines = set(), []
    for t in texts:
        for line in re.split(r"[\r\n]+", t or ""):
            line = re.sub(r"\s+", " ", line).strip()
            letters = sum(ch.isalnum() for ch in line)
            if letters < 2:
                continue
            k = line.casefold()
            if k in seen:
                continue
            seen.add(k)
            lines.append(line)
    return "\n".join(lines)


def has_real_text(ocr: str) -> bool:
    """Florence occasionally reads a letter or two out of texture. A word of
    three letters or more is the bar for "this picture has text in it"."""
    return len(re.findall(r"[^\W\d_]{3,}", ocr, flags=re.UNICODE)) >= 1


def _caption_frame(visual: D.Visual, measured: M.Measured) -> int:
    """Which frame to describe: the brightest for an effect on black (the
    flash itself), the middle one otherwise."""
    if not visual.frames:
        return 0
    if "Black-Background" in measured.tags or "Flash" in measured.tags:
        lum = [float(f[..., :3].mean()) for f in visual.frames]
        return int(np.argmax(lum))
    return len(visual.frames) // 2


def description_text(path: Path, r: Result) -> str:
    """What the text embedder reads for a file: its name, what it looks like,
    what it says, and its tags."""
    stem = re.sub(r"[_\-.]+", " ", path.stem)
    parts = [stem]
    if r.caption:
        parts.append(r.caption)
    if r.ocr:
        parts.append(r.ocr[:1000])
    if r.text_excerpt:
        parts.append(r.text_excerpt[:3000])
    tags = r.selected()
    if tags:
        parts.append("Tags: " + ", ".join(t.replace("-", " ") for t in tags))
    return "\n".join(parts)


# ── the batch ───────────────────────────────────────────────────────────────

def analyse_batch(paths: list, models: Models, bank: PromptBank, on_error=None,
                  use_cache: bool = True) -> list[Result]:
    """Analyse a batch; files that fail are reported through `on_error` and
    left out. Model calls are batched across the files."""
    results: list[Result] = []
    visuals: list[D.Visual | None] = []
    measured: list[M.Measured | None] = []
    todo_idx: list[int] = []

    for item in paths:
        # Paths are reported back exactly as they were given, so the app can
        # match them to its own strings byte for byte.
        raw = item if isinstance(item, str) else str(item)
        path = Path(raw)
        kind = K.kind_of(path) or ""
        if use_cache:
            cached = load_cached(path, models, raw)
            if cached is not None:
                results.append(cached)
                visuals.append(None)
                measured.append(None)
                continue
        r = Result(path=raw, kind=kind)
        try:
            v = D.load_visual(path, kind) if kind != K.AUDIO else D.Visual()
            m = M.measure(v, kind)
            if kind == K.MODEL:
                for fact, tag in (("rigged", "Rigged"), ("animated", "Animated"),
                                  ("textured", "Textured"), ("low_poly", "Low-Poly")):
                    if v.extra.get(fact):
                        m.add(tag, 1.0)
                m.metrics.update({k: v.extra[k] for k in ("triangles", "vertices", "animations", "extents")
                                  if k in v.extra})
            if kind == K.DOCUMENT:
                r.text_excerpt = D.read_text(path)
            r.metrics = m.metrics
            for tag, score in m.tags.items():
                r.scores[tag] = (score, M.MEASURED_THRESHOLD, False)
            if v.frames:
                tp = thumb_path(raw)
                D.thumbnail_png(v.frames[_caption_frame(v, m)], tp)
                r.thumb = str(tp)
        except Exception as e:
            if on_error:
                on_error(raw, str(e))
            results.append(None)
            visuals.append(None)
            measured.append(None)
            continue
        todo_idx.append(len(results))
        results.append(r)
        visuals.append(v)
        measured.append(m)

    # SigLIP over every frame of every file in one pass.
    if models.siglip is not None:
        all_frames, owner = [], []
        for i in todo_idx:
            for f in visuals[i].frames:
                all_frames.append(f)
                owner.append(i)
        if all_frames:
            vecs = models.siglip.embed_images(all_frames)
            owner = np.array(owner)
            for i in todo_idx:
                fv = vecs[owner == i]
                if len(fv) == 0:
                    continue
                pooled = fv.mean(axis=0)
                results[i].visual_vec = pooled / max(np.linalg.norm(pooled), 1e-8)
                for tag, val in zero_shot(fv, results[i].kind, bank, models.siglip).items():
                    if tag not in results[i].scores:  # a measurement outranks a guess
                        results[i].scores[tag] = val

    # Florence: one caption per file, OCR on up to three frames.
    if models.florence is not None:
        cap_frames, cap_owner, ocr_frames, ocr_owner = [], [], [], []
        for i in todo_idx:
            v, r = visuals[i], results[i]
            if not v.frames:
                continue
            cap_frames.append(v.frames[_caption_frame(v, measured[i])])
            cap_owner.append(i)
            # A document with a text layer has no need of OCR; a scanned one does.
            if r.kind == K.DOCUMENT and r.text_excerpt.strip():
                continue
            if r.kind == K.MODEL:
                continue
            picks = [len(v.frames) // 2] if len(v.frames) < 3 else \
                sorted({0, len(v.frames) // 2, len(v.frames) - 1})
            for fi in picks:
                ocr_frames.append(v.frames[fi])
                ocr_owner.append(i)
        if cap_frames:
            for i, text in zip(cap_owner, models.florence.captions(cap_frames)):
                results[i].caption = text
        if ocr_frames:
            per_file: dict[int, list[str]] = {}
            for i, text in zip(ocr_owner, models.florence.ocr(ocr_frames)):
                per_file.setdefault(i, []).append(text)
            for i, texts in per_file.items():
                results[i].ocr = clean_ocr(texts)
                if has_real_text(results[i].ocr):
                    results[i].scores["Has-Text"] = (0.9, M.MEASURED_THRESHOLD, False)
                if results[i].kind == K.DOCUMENT and not results[i].text_excerpt.strip():
                    results[i].text_excerpt = results[i].ocr

    # E5: what each file says or is described as, and document categories.
    if models.text is not None and todo_idx:
        texts = [description_text(Path(results[i].path), results[i]) for i in todo_idx]
        vecs = models.text.embed(texts, kind="passage")
        for i, vec in zip(todo_idx, vecs):
            results[i].text_vec = vec
            if results[i].kind == K.DOCUMENT and bank.doc_vecs is not None and results[i].text_excerpt.strip():
                sims = bank.doc_vecs @ vec
                probs = np.exp((sims - sims.max()) / 0.02)
                probs /= probs.sum()
                for label, p in zip(bank.doc_labels, probs):
                    results[i].scores[label] = (float(p), V.DOCUMENT_THRESHOLD, False)
        if any(K.kind_of(p) == K.DOCUMENT and p.suffix.lower() in (".srt", ".vtt") for p in paths):
            for i in todo_idx:
                if Path(results[i].path).suffix.lower() in (".srt", ".vtt"):
                    results[i].scores["Subtitles"] = (0.95, V.DOCUMENT_THRESHOLD, False)

    for i in todo_idx:
        missing = [n for n in ("siglip", "florence", "text") if getattr(models, n) is None]
        if missing:
            results[i].notes.append("not run: " + ", ".join(missing))
        store(results[i], Path(results[i].path), models)
    return [r for r in results if r is not None]
