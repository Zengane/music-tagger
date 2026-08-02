"""Review UI for the music tagger.

The model does the tagging; this exists so you can skim its suggestions, fix
the ones it got wrong, and have those corrections feed the next training run.
"""

from __future__ import annotations

import os
import threading
import traceback
import webbrowser
from pathlib import Path

import numpy as np
from flask import Flask, jsonify, render_template, request, send_file

from mtag.dataset import EmbeddingCache
from mtag.encoders import get_encoder
from mtag.model import MODEL_PATH, Tagger
from mtag.sidecar import read_taxonomy_tags, read_tags, write_tags
from mtag.taxonomy import ALL_TAGS, AUDIO_EXTS, MOOD_TAGS, SOUND_TAGS
from mtag import audio as A, organize

app = Flask(__name__)

_state = {"status": "loading", "detail": "", "tagger": None, "encoder": None, "cache": None}
_batch = {"running": False, "done": 0, "total": 0, "error": "", "results": {}}
_retrain = {"running": False, "log": "", "error": ""}


def _boot():
    try:
        if not MODEL_PATH.exists():
            _state["status"] = "no-model"
            _state["detail"] = f"No trained model at {MODEL_PATH}. Run train.py first."
            return
        tagger = Tagger.load()
        _state["detail"] = f"loading encoder {tagger.encoder_name}"
        enc = get_encoder(tagger.encoder_name)
        _state.update(status="ready", tagger=tagger, encoder=enc,
                      cache=EmbeddingCache(tagger.encoder_name), detail="")
    except Exception as e:
        traceback.print_exc()
        _state["status"] = "error"
        _state["detail"] = str(e)


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


@app.route("/api/tags-meta")
def api_tags_meta():
    return jsonify({"mood": MOOD_TAGS, "sound": SOUND_TAGS})


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
    if not folder or not os.path.isdir(folder):
        return jsonify({"error": "Invalid folder"}), 400

    files = []
    for f in A.find_audio(folder, AUDIO_EXTS, recursive=recursive):
        tax = read_taxonomy_tags(f)
        if only_untagged and tax:
            continue
        files.append({
            "name": f.name,
            "rel": str(f.relative_to(folder)),
            "path": str(f),
            "existing_tags": tax,
            "other_tags": [t for t in read_tags(f) if t not in ALL_TAGS],
        })
    return jsonify({"files": files})


@app.route("/api/analyze", methods=["POST"])
def api_analyze():
    if _state["status"] != "ready":
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
    if _state["status"] != "ready":
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


@app.route("/api/save", methods=["POST"])
def api_save():
    fp = request.json.get("path", "")
    tags = request.json.get("tags", [])
    if not fp:
        return jsonify({"error": "No path"}), 400
    unknown = [t for t in tags if t not in ALL_TAGS]
    if unknown:
        return jsonify({"error": f"Unknown tags: {unknown}"}), 400
    try:
        write_tags(fp, tags)
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
    if _state["status"] != "ready":
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
    threading.Thread(target=_boot, daemon=True).start()
    threading.Timer(1.5, lambda: webbrowser.open("http://127.0.0.1:5000")).start()
    app.run(debug=False, port=5000, use_reloader=False)
