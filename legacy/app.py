"""Review UI for the music tagger.

The model does the tagging; this exists so you can skim its suggestions, fix
the ones it got wrong, and have those corrections feed the next training run.
"""

from __future__ import annotations

import os
import re
import threading
import traceback
import gc
import hashlib
import json
from urllib.parse import quote
from pathlib import Path

import numpy as np
from flask import Flask, jsonify, render_template, request, send_file

import sys as _sys
# Moved to legacy/ on 2026-09-25. The project root holds mtag/, the model and
# libraries.json, so it goes on the path and data paths point there.
_sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent))

from mtag.dataset import EmbeddingCache
from mtag.encoders import get_encoder
from mtag.model import MODEL_PATH, Tagger
from mtag.sidecar import read_sfx_tags, read_taxonomy_tags, read_tags, write_tags
from mtag.taxonomy import (ALL_TAGS, AUDIO_EXTS, GAME_TAGS, LIBRARY_TAGS,
                           MOOD_TAGS, SFX_TAGS, SOUND_TAGS)
from mtag import audio as A, gametag, organize, search

app = Flask(__name__)

_state = {"status": "idle", "detail": "Models load only when you start tagging.",
          "tagger": None, "encoder": None, "cache": None}
_model_lock = threading.Lock()
_batch = {"running": False, "done": 0, "total": 0, "error": "", "results": {}}
_retrain = {"running": False, "log": "", "error": ""}
_wave_cache = {}
_wave_build = {"running": False, "done": 0, "total": 0}
_APP_DIR = Path(__file__).resolve().parent.parent  # the project root
_WAVE_DIR = _APP_DIR / "cache" / "waveforms"
_CLIP_DIR = _APP_DIR / "cache" / "clips"
_LIBRARIES_PATH = _APP_DIR / "libraries.json"
_TAG_LIBRARY_PATH = _APP_DIR / "tag_library.json"
_settings_lock = threading.Lock()


def _load_libraries() -> list[str]:
    try:
        values = json.loads(_LIBRARIES_PATH.read_text(encoding="utf-8")).get("folders", [])
        return [str(Path(v)) for v in values if os.path.isdir(v)]
    except (OSError, ValueError, AttributeError):
        return []


def _remember_library(folder: str) -> None:
    folder = str(Path(folder).resolve())
    with _settings_lock:
        folders = [folder] + [f for f in _load_libraries() if f.lower() != folder.lower()]
        _LIBRARIES_PATH.write_text(json.dumps({"folders": folders[:12]}, indent=2), encoding="utf-8")


def _default_tag_groups() -> list[dict]:
    return [
        {"name": "Mood", "tags": MOOD_TAGS[:]},
        {"name": "Sound", "tags": SOUND_TAGS[:]},
        {"name": "SFX", "tags": SFX_TAGS[:]},
        {"name": "Game", "tags": GAME_TAGS[:]},
        {"name": "Favorites", "tags": ["⭐", "★", "🌟", "☆"]},
    ]


def _tag_groups() -> list[dict]:
    try:
        payload = json.loads(_TAG_LIBRARY_PATH.read_text(encoding="utf-8"))
        groups = payload.get("groups", [])
        if isinstance(groups, list) and all(isinstance(g, dict) for g in groups):
            return [{"name": str(g.get("name", "Untitled")),
                     "tags": sorted({str(t) for t in g.get("tags", []) if str(t)}, key=str.casefold)}
                    for g in groups]
    except (OSError, ValueError, AttributeError):
        pass
    return _default_tag_groups()


def _save_tag_groups(groups: list[dict]) -> None:
    _TAG_LIBRARY_PATH.write_text(json.dumps({"groups": groups}, ensure_ascii=False, indent=2), encoding="utf-8")


def _wave_key(path: Path, points: int) -> str:
    st = path.stat()
    return hashlib.sha256(f"{path.resolve()}|{st.st_size}|{st.st_mtime_ns}|{points}".encode()).hexdigest()


def _get_waveform(path: Path, points: int) -> dict:
    key = _wave_key(path, points)
    if key in _wave_cache:
        return _wave_cache[key]
    disk = _WAVE_DIR / f"{key}.json"
    try:
        wave = json.loads(disk.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        wave = A.waveform(path, points)
        _WAVE_DIR.mkdir(parents=True, exist_ok=True)
        disk.write_text(json.dumps(wave, separators=(",", ":")), encoding="utf-8")
    _wave_cache[key] = wave
    if len(_wave_cache) > 256:
        _wave_cache.pop(next(iter(_wave_cache)))
    return wave


def _warm_waveforms(paths: list[str], points: int = 2400) -> None:
    _wave_build.update(running=True, done=0, total=len(paths))
    try:
        for raw in paths:
            try:
                _get_waveform(Path(raw), points)
            except Exception:
                pass
            _wave_build["done"] += 1
    finally:
        _wave_build["running"] = False


def _load_model() -> bool:
    """Load the tagger on demand, never while simply browsing the library."""
    if _state["status"] == "ready":
        return True
    with _model_lock:
        if _state["status"] == "ready":
            return True
        _state["status"] = "loading"
        _state["detail"] = "loading tag model"
        try:
            if not MODEL_PATH.exists():
                _state["status"] = "no-model"
                _state["detail"] = f"No trained model at {MODEL_PATH}. Run train.py first."
                return False
            tagger = Tagger.load()
            _state["detail"] = f"loading encoder {tagger.encoder_name}"
            enc = get_encoder(tagger.encoder_name)
            _state.update(status="ready", tagger=tagger, encoder=enc,
                          cache=EmbeddingCache(tagger.encoder_name), detail="")
            return True
        except Exception as e:
            traceback.print_exc()
            _state["status"] = "error"
            _state["detail"] = str(e)
            return False


def _boot() -> bool:
    """Compatibility entry point for deliberate model warm-up callers."""
    return _load_model()


def _unload_model() -> bool:
    """Return encoder VRAM when the user leaves the explicit tagging workflow."""
    if _batch["running"] or _retrain["running"]:
        return False
    with _model_lock:
        _state.update(status="idle", detail="Models load only when you start tagging.",
                      tagger=None, encoder=None, cache=None)
        gc.collect()
        try:
            import torch
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        except Exception:
            pass
    return True


def _embed(path: Path) -> np.ndarray:
    cache, enc = _state["cache"], _state["encoder"]
    vec = cache.get(path)
    if vec is None:
        vec = enc.embed_file(path)
        cache.put(path, vec)
    return vec


def _analyze(path: Path) -> dict:
    return _state["tagger"].suggest(_embed(path))


# ── routes ────────────────────────────────────────────────────────────────────
@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/status")
def api_status():
    import torch
    return jsonify({
        "status": _state["status"],
        "detail": _state["detail"],
        "device": "cuda" if torch.cuda.is_available() else "cpu",
        "encoder": _state["tagger"].encoder_name if _state["tagger"] else None,
    })


@app.route("/api/model-info")
def api_model_info():
    t = _state["tagger"]
    if not t:
        return jsonify({"error": "no model"}), 503
    tags = {}
    for tag in ALL_TAGS:
        if tag in t.probes:
            m = t.probes[tag]
            tags[tag] = {"source": "probe", "n_pos": m["n_pos"], "ap": m["cv_ap"],
                         "precision": m["cv_precision"], "recall": m["cv_recall"],
                         "threshold": m["threshold"]}
        elif tag in t.zeroshot:
            z = t.zeroshot[tag]
            tags[tag] = {"source": "zeroshot", "n_pos": z["n_pos"], "threshold": z["threshold"]}
        else:
            tags[tag] = {"source": "manual", "n_pos": 0}
    return jsonify({"encoder": t.encoder_name, "meta": t.meta, "tags": tags})


@app.route("/api/unload-model", methods=["POST"])
def api_unload_model():
    if not _unload_model():
        return jsonify({"error": "Tagging is still running"}), 409
    return jsonify({"ok": True})


@app.route("/api/tags-meta")
def api_tags_meta():
    return jsonify({"mood": MOOD_TAGS, "sound": SOUND_TAGS, "sfx": SFX_TAGS,
                    "game": GAME_TAGS,
                    "search_syntax": "AND search: tag:Epic tag:Orchestral game:Celeste"})


@app.route("/api/tag-library", methods=["GET", "POST"])
def api_tag_library():
    if request.method == "GET":
        return jsonify({"groups": _tag_groups()})
    data = request.json or {}
    action = data.get("action")
    groups = _tag_groups()
    group_name = str(data.get("group", "")).strip()
    if action == "add":
        tag = str(data.get("tag", "")).strip()
        if not tag or any(c in tag for c in "\\/#"):
            return jsonify({"error": "Tag must be non-empty and cannot contain \\, /, or #"}), 400
        target = next((g for g in groups if g["name"] == group_name), None)
        if target is None:
            target = {"name": group_name or "Custom", "tags": []}
            groups.append(target)
        if tag not in target["tags"]:
            target["tags"].append(tag)
    elif action == "edit":
        old, new = str(data.get("old", "")).strip(), str(data.get("new", "")).strip()
        if not old or not new or any(c in new for c in "\\/#"):
            return jsonify({"error": "Invalid tag name"}), 400
        for g in groups:
            if old in g["tags"]:
                g["tags"] = [new if t == old else t for t in g["tags"]]
                break
    elif action == "delete":
        tag = str(data.get("tag", "")).strip()
        for g in groups:
            g["tags"] = [t for t in g["tags"] if t != tag]
    else:
        return jsonify({"error": "Unknown tag-library action"}), 400
    for g in groups:
        g["tags"] = sorted(set(g["tags"]), key=str.casefold)
    _save_tag_groups(groups)
    return jsonify({"groups": groups})


@app.route("/api/browse")
def api_browse():
    import tkinter as tk
    from tkinter import filedialog
    root = tk.Tk()
    root.withdraw()
    root.wm_attributes("-topmost", 1)
    folder = filedialog.askdirectory(title="Select Music Folder")
    root.destroy()
    return jsonify({"path": folder or ""})


@app.route("/api/scan", methods=["POST"])
def api_scan():
    folder = request.json.get("folder", "")
    recursive = bool(request.json.get("recursive", False))
    only_untagged = bool(request.json.get("only_untagged", False))
    include_sfx = bool(request.json.get("include_sfx", False))
    query = (request.json.get("query") or "").strip()
    if not folder or not os.path.isdir(folder):
        return jsonify({"error": "Invalid folder"}), 400

    library = request.json.get("library") or folder
    _remember_library(folder)

    files = []
    skip_dirs = () if include_sfx else A.SKIP_DIRS
    for f in A.find_audio(folder, AUDIO_EXTS, recursive=recursive, skip_dirs=skip_dirs):
        all_tags = read_tags(f)
        if query and not search.matches(f, query, all_tags):
            continue
        tax = read_taxonomy_tags(f)
        sfx_tags = read_sfx_tags(f)
        if only_untagged and (tax or sfx_tags):
            continue
        others = [t for t in all_tags if t not in LIBRARY_TAGS]
        have_game = gametag.existing_game_tags(others)
        guess, source, is_new = (None, None, False) if have_game \
            else gametag.detect_detail(f, library)
        files.append({
            "name": f.name,
            "rel": str(f.relative_to(folder)),
            "path": str(f),
            "existing_tags": tax,
            "sfx_tags": sfx_tags,
            "all_tags": all_tags,
            "other_tags": others,
            "kind": "sfx" if any(part.lower() == "sfx" for part in f.relative_to(folder).parts[:-1]) else "music",
            "game": have_game[0] if have_game else None,
            # Only offered when the file has no game tag of its own; a hand-picked
            # one always wins over a name guessed off the filename.
            "game_guess": guess,
            "game_guess_from": source,
            "game_is_new": is_new,
        })
    # Waveform generation is deliberately independent of the tag model and
    # happens after the library response so import and playback stay responsive.
    if files and not _wave_build["running"]:
        threading.Thread(target=_warm_waveforms, args=([f["path"] for f in files],), daemon=True).start()
    return jsonify({"files": files, "tags": sorted({t for f in files for t in f["all_tags"]}, key=str.casefold)})


@app.route("/api/libraries")
def api_libraries():
    return jsonify({"folders": _load_libraries()})


@app.route("/api/analyze", methods=["POST"])
def api_analyze():
    if not _load_model():
        return jsonify({"error": _state["detail"] or "Model not ready"}), 503
    fp = request.json.get("path", "")
    if not fp or not os.path.isfile(fp):
        return jsonify({"error": "File not found"}), 404
    try:
        return jsonify(_analyze(Path(fp)))
    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": str(e)}), 500


def _run_batch(paths: list[str]):
    _batch.update(running=True, done=0, total=len(paths), error="", results={})
    try:
        for p in paths:
            try:
                _batch["results"][p] = _analyze(Path(p))
            except Exception as e:
                _batch["results"][p] = {"error": str(e)}
            _batch["done"] += 1
    except Exception as e:
        _batch["error"] = str(e)
        traceback.print_exc()
    finally:
        _batch["running"] = False


@app.route("/api/analyze-batch", methods=["POST"])
def api_analyze_batch():
    if not _load_model():
        return jsonify({"error": _state["detail"] or "Model not ready"}), 503
    if _batch["running"]:
        return jsonify({"error": "Batch already running"}), 409
    paths = request.json.get("paths", [])
    if not paths:
        return jsonify({"error": "No files"}), 400
    threading.Thread(target=_run_batch, args=[paths], daemon=True).start()
    return jsonify({"ok": True, "total": len(paths)})


@app.route("/api/batch-progress")
def api_batch_progress():
    want_results = request.args.get("results") == "1"
    out = {k: _batch[k] for k in ("running", "done", "total", "error")}
    if want_results:
        out["results"] = _batch["results"]
    return jsonify(out)


@app.route("/api/audio")
def api_audio():
    fp = request.args.get("path", "")
    if not fp or not os.path.isfile(fp):
        return "Not found", 404
    return send_file(fp, conditional=True)


@app.route("/api/waveform")
def api_waveform():
    fp = request.args.get("path", "")
    if not fp or not os.path.isfile(fp):
        return "Not found", 404
    try:
        points = max(64, min(4000, int(request.args.get("points", "1200"))))
    except ValueError:
        points = 1200
    return jsonify(_get_waveform(Path(fp), points))


@app.route("/api/waveform-progress")
def api_waveform_progress():
    return jsonify(_wave_build)


@app.route("/api/clip", methods=["POST"])
def api_clip():
    data = request.json or {}
    fp = data.get("path", "")
    try:
        start, end = float(data.get("start", 0)), float(data.get("end", 0))
    except (TypeError, ValueError):
        return jsonify({"error": "Invalid selection"}), 400
    if not fp or not os.path.isfile(fp) or start < 0 or end <= start:
        return jsonify({"error": "Invalid source or selection"}), 400
    source = Path(fp)
    duration = A.duration_seconds(source)
    end = min(end, duration)
    if end - start < 0.05:
        return jsonify({"error": "Selection is too short"}), 400
    key = hashlib.sha256(f"{source.resolve()}|{source.stat().st_mtime_ns}|{start:.3f}|{end:.3f}".encode()).hexdigest()
    output = _CLIP_DIR / f"{source.stem}-{start:.2f}-{end:.2f}-{key[:8]}.wav"
    try:
        if not output.exists():
            _CLIP_DIR.mkdir(parents=True, exist_ok=True)
            A.export_clip(source, start, end, output)
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    return jsonify({"name": output.name, "url": "/api/clip-file?path=" + quote(str(output))})


@app.route("/api/clip-file")
def api_clip_file():
    path = Path(request.args.get("path", ""))
    try:
        path.resolve().relative_to(_CLIP_DIR.resolve())
    except ValueError:
        return "Not found", 404
    if not path.is_file():
        return "Not found", 404
    return send_file(path, conditional=True, as_attachment=True, download_name=path.name)


@app.route("/api/save", methods=["POST"])
def api_save():
    fp = request.json.get("path", "")
    tags = request.json.get("tags", [])
    game = request.json.get("game") or None
    if not fp:
        return jsonify({"error": "No path"}), 400
    unknown = [t for t in tags if t not in LIBRARY_TAGS]
    if unknown:
        return jsonify({"error": f"Unknown tags: {unknown}"}), 400
    # A game tag not in the library is only written when the caller says so —
    # most of a fresh drop is games the tag library hasn't heard of, but a typo
    # shouldn't be able to invent one silently.
    if game and game not in GAME_TAGS and not request.json.get("allow_new_game"):
        return jsonify({"error": f"Unknown game tag: {game}"}), 400
    if game and not re.fullmatch(r"[\w&'.\- ]{1,60}", game):
        return jsonify({"error": f"Invalid game tag: {game!r}"}), 400
    try:
        write_tags(fp, tags, game=game)
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/organize-plan", methods=["POST"])
def api_organize_plan():
    """Dry run: what moving these files would do. Changes nothing on disk."""
    library = request.json.get("library", "")
    items = request.json.get("items", [])  # [{path, mood}]
    if not library or not os.path.isdir(library):
        return jsonify({"error": "Invalid library folder"}), 400

    plans = []
    for it in items:
        mood = it.get("mood")
        if mood not in MOOD_TAGS:
            plans.append({"src": it.get("path", ""), "status": "no-mood", "mood": mood})
            continue
        plans.append(organize.plan(it["path"], library, mood))
    return jsonify({"plans": plans})


@app.route("/api/organize", methods=["POST"])
def api_organize():
    library = request.json.get("library", "")
    items = request.json.get("items", [])
    if not library or not os.path.isdir(library):
        return jsonify({"error": "Invalid library folder"}), 400

    results = []
    for it in items:
        mood = it.get("mood")
        if mood not in MOOD_TAGS:
            results.append({"src": it.get("path", ""), "status": "no-mood", "moved": False})
            continue
        try:
            results.append(organize.apply(organize.plan(it["path"], library, mood)))
        except Exception as e:
            traceback.print_exc()
            results.append({"src": it["path"], "status": "error",
                            "moved": False, "error": str(e)})
    return jsonify({"results": results})


@app.route("/api/mood-folders")
def api_mood_folders():
    library = request.args.get("library", "")
    if not library or not os.path.isdir(library):
        return jsonify({"error": "Invalid library folder"}), 400
    existing = organize.mood_folders(library)
    return jsonify({
        "folders": {t: (existing[t].name if t in existing else None) for t in MOOD_TAGS}
    })


def _run_retrain(library: str):
    _retrain.update(running=True, log="", error="")
    try:
        import train as train_mod
        import io, contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            train_mod.train(library, _state["tagger"].encoder_name)
        _retrain["log"] = buf.getvalue()
        _state["tagger"] = Tagger.load()
    except Exception as e:
        _retrain["error"] = str(e)
        traceback.print_exc()
    finally:
        _retrain["running"] = False


@app.route("/api/retrain", methods=["POST"])
def api_retrain():
    if not _load_model():
        return jsonify({"error": "Model not ready"}), 503
    if _retrain["running"]:
        return jsonify({"error": "Retrain already running"}), 409
    library = request.json.get("library", "") or _state["tagger"].meta.get("library", "")
    if not library or not os.path.isdir(library):
        return jsonify({"error": "Invalid library folder"}), 400
    threading.Thread(target=_run_retrain, args=[library], daemon=True).start()
    return jsonify({"ok": True})


@app.route("/api/retrain-progress")
def api_retrain_progress():
    return jsonify(_retrain)


if __name__ == "__main__":
    app.run(debug=False, port=5000, use_reloader=False)
