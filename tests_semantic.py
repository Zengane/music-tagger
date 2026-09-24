"""Natural-language search ranking, with stand-in encoders.

The index has to put matches from different models on one scale, fold in the
words a file literally carries, and return nothing rather than noise when
nothing matches. None of that needs a real model to check.

    python tests_semantic.py
"""

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

import mtag.dataset as DS
import mtag.semantic as S


class Fake:
    """Maps a query to a fixed direction."""

    def __init__(self, table, dim):
        self.table, self.dim = table, dim

    def embed_query(self, texts):
        v = np.zeros(self.dim, np.float32)
        for word, axis in self.table.items():
            if word in texts[0]:
                v[axis] = 1
        return v[None, :] if v.any() else None


class SemanticSearch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self._cache = DS.CACHE_ROOT
        DS.CACHE_ROOT = S.CACHE_ROOT = root / "cache"
        lib = root / "lib"
        lib.mkdir()
        rng = np.random.default_rng(0)
        self.paths = []
        # 40 filler images, pointing nowhere in particular. 64 dimensions, so
        # unrelated vectors are nearly orthogonal, as real embeddings are.
        for i in range(40):
            p = lib / f"file{i:02d}.png"
            p.write_bytes(b"x" * (i + 1))
            self.paths.append(str(p))
            self.put("vis", p, rng.normal(size=64))
        # One clear visual match for "explosion" (axis 0).
        boom = lib / "IMG_0001.png"
        boom.write_bytes(b"boom")
        self.paths.append(str(boom))
        self.put("vis", boom, np.eye(64)[0] * 3 + rng.normal(size=64) * 0.1)
        # One sound that matches "explosion" in audio space (axis 2), stored
        # mean+std pooled like the real audio caches.
        snd = lib / "hit.wav"
        snd.write_bytes(b"snd")
        self.paths.append(str(snd))
        self.put("aud", snd, np.concatenate([np.eye(64)[2] * 3 + rng.normal(size=64) * 0.1, np.ones(64)]))
        for i in range(10):
            q = lib / f"s{i}.wav"
            q.write_bytes(b"s" * (i + 1))
            self.paths.append(str(q))
            self.put("aud", q, np.concatenate([rng.normal(size=64), np.ones(64)]))
        # A file whose name says it, with no vector at all.
        named = lib / "Big Explosion Fireball.mov"
        named.write_bytes(b"n")
        self.paths.append(str(named))
        # A meme whose OCR says it (media result cache).
        meme = lib / "meme.jpg"
        meme.write_bytes(b"m")
        self.paths.append(str(meme))
        d = DS.CACHE_ROOT / "media-small"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{DS._key(meme)}.json").write_text(json.dumps(
            {"caption": "a cat sitting at a desk", "ocr": "WHEN THE CODE COMPILES", "scores": {"Meme": [0.9, 0.1, False]}}))

        self.index = S.Index(self.paths, {"vis": False, "aud": True}, media_builds=["small"])
        self.enc = {"vis": Fake({"explosion": 0}, 64), "aud": Fake({"explosion": 2}, 64)}

    def tearDown(self):
        DS.CACHE_ROOT = S.CACHE_ROOT = self._cache
        self.tmp.cleanup()

    def put(self, space, path, vec):
        d = DS.CACHE_ROOT / space
        d.mkdir(parents=True, exist_ok=True)
        np.save(d / f"{DS._key(path)}.npy", np.asarray(vec, np.float32))

    def names(self, hits):
        return [Path(self.paths[i]).name for i, _ in hits]

    def test_counts(self):
        self.assertEqual(self.index.counts(), {"vis": 41, "aud": 11})

    def test_matches_across_spaces_and_words(self):
        got = self.names(self.index.search("explosion", self.enc))
        self.assertIn("IMG_0001.png", got)       # by what it looks like
        self.assertIn("hit.wav", got)            # by what it sounds like
        self.assertIn("Big Explosion Fireball.mov", got)  # by its name
        self.assertLessEqual(len(got), 4, got)   # and not the filler

    def test_ocr_and_caption_are_searchable(self):
        got = self.names(self.index.search("code compiles meme", {}))
        self.assertEqual(got, ["meme.jpg"])

    def test_substrings_inside_words_do_not_match(self):
        self.assertEqual(self.names(self.index.search("cat", {})), ["meme.jpg"])
        self.assertEqual(self.index.search("ode", {}), [])

    def test_nothing_rather_than_noise(self):
        self.assertEqual(self.index.search("submarine", self.enc), [])

    def test_missing_file_is_listed_not_fatal(self):
        idx = S.Index(self.paths + ["/does/not/exist.png"], {"vis": False}, ["small"])
        self.assertEqual(len(idx.files), len(self.paths) + 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
