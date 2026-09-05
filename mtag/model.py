"""The trained tagger: probes for tags with enough labels, zero-shot for the rest."""

from __future__ import annotations

import pickle
from pathlib import Path

import numpy as np

from .taxonomy import ALL_TAGS, MOOD_TAGS, PROMPTS, SOUND_TAGS

MODEL_PATH = Path(__file__).resolve().parent.parent / "model" / "tagger.pkl"


def _unit(v: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return np.divide(v, n, out=np.zeros_like(v), where=n > 0)


def text_block(X: np.ndarray, sl: tuple[int, int] | None) -> np.ndarray:
    """Pull out the columns that share a space with the encoder's text tower.

    For a single encoder that's the mean-pooled half; for a fusion it's the mean
    block of whichever part has a text tower, which sits partway into the concat.
    The slice is renormalised because the full vector was normalised as a whole.
    """
    if sl is None:
        return np.zeros_like(X[..., :1])
    return _unit(X[..., sl[0]:sl[1]])


class Tagger:
    def __init__(self, encoder_name, probes, zeroshot, meta):
        self.encoder_name = encoder_name
        self.probes = probes            # tag -> {coef, intercept, threshold, cv_*}
        self.zeroshot = zeroshot        # tag -> {text_vec, threshold, prevalence}
        self.meta = meta

    @property
    def text_slice(self):
        sl = self.meta.get("text_slice")
        return tuple(sl) if sl else None

    # ---- persistence ----------------------------------------------------
    def save(self, path=MODEL_PATH):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "wb") as f:
            pickle.dump(
                {
                    "encoder_name": self.encoder_name,
                    "probes": self.probes,
                    "zeroshot": self.zeroshot,
                    "meta": self.meta,
                },
                f,
            )

    @classmethod
    def load(cls, path=MODEL_PATH):
        with open(path, "rb") as f:
            d = pickle.load(f)
        return cls(d["encoder_name"], d["probes"], d["zeroshot"], d["meta"])

    # ---- inference ------------------------------------------------------
    def score(self, x: np.ndarray) -> dict[str, dict]:
        """One track embedding -> per-tag score, threshold and provenance."""
        out = {}
        xm = text_block(x, self.text_slice)
        for tag in ALL_TAGS:
            if tag in self.probes:
                m = self.probes[tag]
                z = float(np.dot(m["coef"], x) + m["intercept"])
                p = 1.0 / (1.0 + np.exp(-z))
                out[tag] = {
                    "score": p,
                    "threshold": m["threshold"],
                    "source": "probe",
                    # Whether this tag is trusted to apply itself. See
                    # TARGET_PRECISION in probes.py: a tag that cannot be right
                    # 70% of the time is still scored and still ranked, it is
                    # just never written to a file without being asked.
                    "auto": bool(m.get("auto", True)),
                    "cv_precision": m.get("cv_precision"),
                    "cv_recall": m.get("cv_recall"),
                    "n_pos": m.get("n_pos"),
                }
            elif tag in self.zeroshot:
                z = self.zeroshot[tag]
                sim = float(np.dot(xm, z["text_vec"]))
                out[tag] = {
                    "score": sim,
                    "threshold": z["threshold"],
                    "source": "zeroshot",
                    # A tag with too few examples to train on is a guess from a
                    # text prompt. Those are offered, never applied.
                    "auto": False,
                    "n_pos": z.get("n_pos", 0),
                }
            else:
                out[tag] = {"score": 0.0, "threshold": 1.0, "source": "none", "n_pos": 0}
        return out

    def suggest(self, x: np.ndarray) -> dict:
        """Scores, plus the tags trusted enough to apply themselves.

        Everything is scored and everything is ranked; only the tags that
        earned a threshold at the target precision are applied. The rest reach
        the interface as suggestions with their score, which is one click to
        accept and no clicks to ignore.
        """
        scores = self.score(x)
        selected = [
            t for t, s in scores.items()
            if s.get("auto", True) and s["score"] >= s["threshold"]
        ]
        return {
            "scores": scores,
            "selected": selected,
            "mood": [t for t in selected if t in MOOD_TAGS],
            "sound": [t for t in selected if t in SOUND_TAGS],
        }


def build_zeroshot(encoder, X_library: np.ndarray, Y: np.ndarray, tags: list[str]) -> dict:
    """Zero-shot heads for tags with too few labels to train a probe.

    Absolute cosine similarities aren't comparable across tags, so each tag's
    threshold is set at a quantile of the library's own score distribution,
    picked so the tag fires about three times as often as it currently appears.
    Over-firing is the right bias here: these are rare tags the user will be
    reviewing by hand anyway, and a suggestion they can reject beats silence.
    """
    sl = encoder.text_slice(X_library.shape[1])
    text = encoder.embed_text([PROMPTS[t] for t in tags]) if sl else None
    if text is None:
        return {}
    text = _unit(np.asarray(text, dtype=np.float32))
    Xm = text_block(X_library, sl)

    heads = {}
    for i, tag in enumerate(tags):
        sims = Xm @ text[i]
        n_pos = int(Y[:, ALL_TAGS.index(tag)].sum())
        prevalence = max(n_pos, 1) / len(sims)
        q = 1.0 - min(0.05, prevalence * 3)
        heads[tag] = {
            "text_vec": text[i],
            "threshold": float(np.quantile(sims, q)),
            "prevalence": prevalence,
            "n_pos": n_pos,
        }
    return heads
