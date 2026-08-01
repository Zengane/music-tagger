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


def best_threshold(y, probs, beta=1.5) -> tuple[float, float, float, float]:
    """Threshold maximising F-beta.

    beta > 1 leans toward recall: a missed tag is invisible in TagSpaces, while
    a wrong one is a single click to remove during review.

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
        thr, prec, rec, f = best_threshold(y, oof)
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
        })

    trainable = [r for r in rows if r.get("trainable")]
    summary = {
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
