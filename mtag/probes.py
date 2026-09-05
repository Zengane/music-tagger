"""Per-tag classifiers trained on the user's own sidecar labels.

One independent binary logistic regression per tag on top of a frozen audio
embedding. This is the whole point of the rewrite: the tag vocabulary is
personal ("Goofy", "Build-Up", "Awkward" mean what *this* library says they
mean), so a model that reads the user's labels will always beat a zero-shot
model reading a text prompt.

Tags with too few positive examples to train on fall back to zero-shot text
similarity, if the encoder has a text tower.
"""

from __future__ import annotations

import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, roc_auc_score
from sklearn.model_selection import StratifiedKFold

from .taxonomy import ALL_TAGS

# Below this many positives a probe overfits to a handful of tracks; the tag is
# routed to zero-shot instead and flagged for manual review in the UI.
MIN_POSITIVES = 12

C_GRID = (0.1, 0.5, 1.0, 4.0, 16.0)

# Threshold bias, per tag. Above 1 favours recall, below 1 favours precision.
#
# This was 1.5 — leaning hard toward recall — on the reasoning that a missing
# tag is invisible while a wrong one is one click to remove. That was true when
# the tags were reviewed in TagSpaces. It is not true now: the Tagging tab puts
# every suggestion in front of you, so a wrong tag is not a click to remove, it
# is a judgement to make, on every file, forever. At beta 1.5 the model was
# right about half the time (macro precision 0.50 at recall 0.74), which reads
# exactly like "it doesn't tag things the way I would" — because half of what
# it said, you disagreed with.
#
# Below 1 the threshold moves the other way: fewer suggestions, and the ones
# that come are ones you will usually keep. The tags it now stays quiet about
# are the ones it was never sure of anyway.
DEFAULT_BETA = 0.7

# Per-tag exceptions.
#
# Vocals exists to filter tracks *out* of an edit, so a false positive quietly
# retires a usable instrumental — it stays stricter than the rest. Choir has
# the same job on a smaller scale.
TAG_BETA = {
    "Vocals": 0.5,
    "Choir": 0.7,
}

# Set by train.py from --beta, so the trade-off can be moved without editing
# this file. None means "use the values above".
BETA_OVERRIDE: float | None = None


def beta_for(tag: str) -> float:
    if BETA_OVERRIDE is not None:
        # The per-tag exceptions keep their relative strictness.
        return BETA_OVERRIDE * (TAG_BETA.get(tag, DEFAULT_BETA) / DEFAULT_BETA)
    return TAG_BETA.get(tag, DEFAULT_BETA)


def _fit_one(X, y, C):
    clf = LogisticRegression(
        C=C, max_iter=3000, class_weight="balanced", solver="lbfgs"
    )
    clf.fit(X, y)
    return clf


def out_of_fold_scores(X, y, n_splits=5, seed=0) -> tuple[np.ndarray, float]:
    """Out-of-fold probabilities for one tag, with C picked on the same folds.

    Returns (oof_probabilities, best_C). Picking C on the outer folds slightly
    flatters the score; it is applied identically to every encoder, so the
    bakeoff comparison stays fair.
    """
    n_pos = int(y.sum())
    n_splits = min(n_splits, n_pos, len(y) - n_pos)
    if n_splits < 2:
        return np.full(len(y), y.mean(), dtype=float), C_GRID[2]

    best, best_ap, best_C = None, -1.0, C_GRID[0]
    for C in C_GRID:
        oof = np.zeros(len(y), dtype=float)
        skf = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=seed)
        for tr, te in skf.split(X, y):
            oof[te] = _fit_one(X[tr], y[tr], C).predict_proba(X[te])[:, 1]
        ap = average_precision_score(y, oof)
        if ap > best_ap:
            best, best_ap, best_C = oof, ap, C
    return best, best_C


# How often a suggestion has to be right before it is applied on its own.
#
# One global bias was the wrong shape for this problem. At 1.5 the model applied
# everything it half-believed and was right about half the time; at 0.7 it went
# quiet and applied one or two tags to a track that deserved five. Neither is a
# statement about the model — it is a statement about *thresholds*, and the
# right threshold is different for every tag, because the tags are not equally
# learnable. Victory is separable and Mysterious is not.
#
# So each tag is given the lowest threshold at which it is right this often, and
# keeps as much recall as that allows. A tag that cannot reach it at any
# threshold is not applied at all — it becomes a suggestion, ranked in the list
# with its score, one click to accept. Nothing is lost: what used to be a wrong
# tag on your file is now a proposal you can ignore.
# 0.60, chosen from the sweep in sweep.py rather than by feel.
#
# Zengane tags 3.1 of these per track. At 0.60 the model applies 2.9 — the same
# handful — of which about 1.8 are ones he would have chosen and 1.2 are ones to
# take off. Higher and it goes quiet (1.8 tags at 0.70, of which only 1.2 land);
# lower and the wrong ones outnumber the right. Removing one wrong tag is a
# click; finding two missing ones means listening to the track again.
TARGET_PRECISION = 0.60

# Below this a tag is not worth auto-applying however precise it looks, because
# it would fire on almost nothing.
MIN_RECALL = 0.15


def threshold_for_precision(y, probs, target=TARGET_PRECISION):
    """Lowest threshold that is right `target` of the time. Recall is maximised.

    Returns (threshold, precision, recall, reached) where `reached` says whether
    the target was actually met — a tag that misses it is suggestion-only.
    """
    order = np.unique(probs)
    if order.size < 2:
        return 0.5, 0.0, 0.0, False
    cands = (order[:-1] + order[1:]) / 2
    if cands.size > 400:
        cands = np.quantile(cands, np.linspace(0, 1, 400))

    best = None
    for t in cands:
        pred = probs >= t
        tp = float((pred & (y == 1)).sum())
        if tp == 0:
            continue
        prec = tp / pred.sum()
        rec = tp / y.sum()
        if prec < target or rec < MIN_RECALL:
            continue
        # Every candidate here already clears the bar, so the one that finds
        # the most is the one to take.
        if best is None or rec > best[2]:
            best = (float(t), prec, rec, True)

    if best is not None:
        return best

    # Cannot be trusted on its own at any threshold. The number handed back is
    # the most precise point it does reach, so the suggestion list still has
    # somewhere sensible to draw its notch.
    fallback = (0.5, 0.0, 0.0, False)
    for t in cands:
        pred = probs >= t
        tp = float((pred & (y == 1)).sum())
        if tp == 0:
            continue
        prec = tp / pred.sum()
        rec = tp / y.sum()
        if rec < MIN_RECALL:
            continue
        if prec > fallback[1]:
            fallback = (float(t), prec, rec, False)
    return fallback


def best_threshold(y, probs, beta=DEFAULT_BETA) -> tuple[float, float, float, float]:
    """Threshold maximising F-beta. See TAG_BETA for why beta varies by tag.

    Returns (threshold, precision, recall, fbeta).
    """
    order = np.unique(probs)
    if order.size < 2:
        return 0.5, 0.0, 0.0, 0.0
    cands = (order[:-1] + order[1:]) / 2
    if cands.size > 400:
        cands = np.quantile(cands, np.linspace(0, 1, 400))

    b2 = beta * beta
    best = (0.5, 0.0, 0.0, -1.0)
    for t in cands:
        pred = probs >= t
        tp = float((pred & (y == 1)).sum())
        if tp == 0:
            continue
        prec = tp / pred.sum()
        rec = tp / y.sum()
        f = (1 + b2) * prec * rec / (b2 * prec + rec)
        if f > best[3]:
            best = (float(t), prec, rec, f)
    return best


def evaluate(X, Y, tags=ALL_TAGS, seed=0) -> dict:
    """Cross-validated per-tag report for one encoder's embeddings."""
    rows = []
    for i, tag in enumerate(tags):
        y = Y[:, i].astype(int)
        n_pos = int(y.sum())
        if n_pos < 2:
            rows.append({"tag": tag, "n_pos": n_pos, "trainable": False})
            continue
        oof, C = out_of_fold_scores(X, y, seed=seed)
        ap = average_precision_score(y, oof)
        try:
            auc = roc_auc_score(y, oof)
        except ValueError:
            auc = float("nan")
        thr, prec, rec, auto = threshold_for_precision(y, oof)
        f = 0.0 if prec + rec == 0 else 2 * prec * rec / (prec + rec)
        prevalence = n_pos / len(y)
        rows.append({
            "tag": tag,
            "n_pos": n_pos,
            "trainable": n_pos >= MIN_POSITIVES,
            "ap": ap,
            "auc": auc,
            "prevalence": prevalence,
            "lift": ap / prevalence,
            "C": C,
            "threshold": thr,
            "precision": prec,
            "recall": rec,
            "f": f,
            # Whether this tag is applied on its own, or only offered.
            "auto": bool(auto),
        })

    trainable = [r for r in rows if r.get("trainable")]
    auto_tags = [r for r in trainable if r.get("auto")]
    summary = {
        "n_auto": len(auto_tags),
        "macro_auto_precision": float(np.mean([r["precision"] for r in auto_tags])) if auto_tags else 0.0,
        "macro_auto_recall": float(np.mean([r["recall"] for r in auto_tags])) if auto_tags else 0.0,
        "macro_ap": float(np.mean([r["ap"] for r in trainable])) if trainable else 0.0,
        "macro_auc": float(np.nanmean([r["auc"] for r in trainable])) if trainable else 0.0,
        "macro_lift": float(np.mean([r["lift"] for r in trainable])) if trainable else 0.0,
        "macro_precision": float(np.mean([r["precision"] for r in trainable])) if trainable else 0.0,
        "macro_recall": float(np.mean([r["recall"] for r in trainable])) if trainable else 0.0,
        "n_trainable": len(trainable),
    }
    return {"per_tag": rows, "summary": summary}


def fit_final(X, Y, report, tags=ALL_TAGS) -> dict:
    """Refit each trainable tag on all data, using the C chosen during CV."""
    by_tag = {r["tag"]: r for r in report["per_tag"]}
    models = {}
    for i, tag in enumerate(tags):
        r = by_tag.get(tag, {})
        if not r.get("trainable"):
            continue
        y = Y[:, i].astype(int)
        clf = _fit_one(X, y, r["C"])
        models[tag] = {
            "coef": clf.coef_[0].astype(np.float32),
            "intercept": float(clf.intercept_[0]),
            "threshold": r["threshold"],
            "auto": bool(r.get("auto", True)),
            "cv_precision": r["precision"],
            "cv_recall": r["recall"],
            "cv_ap": r["ap"],
            "n_pos": r["n_pos"],
        }
    return models


def predict_proba(models: dict, tag: str, x: np.ndarray) -> float:
    m = models[tag]
    z = float(np.dot(m["coef"], x) + m["intercept"])
    return 1.0 / (1.0 + np.exp(-z))
