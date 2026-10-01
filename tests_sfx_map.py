import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import numpy as np
import sfx_map_job
from mtag import sfxmap


def blobs(n_per=12, groups=4, dim=32, seed=0):
    """Clearly separate clusters of unit vectors, and which cluster each is."""
    rng = np.random.default_rng(seed)
    centres = rng.normal(size=(groups, dim))
    X = np.concatenate([c + 0.05 * rng.normal(size=(n_per, dim)) for c in centres])
    return X.astype(np.float32), np.repeat(np.arange(groups), n_per)


class SFXMapTests(unittest.TestCase):
    def test_cached_files_do_not_load_encoder(self):
        with patch.object(sfx_map_job,"EmbeddingCache") as cache:
            cache.return_value.get.return_value=np.ones(8,dtype=np.float32)
            with patch("builtins.__import__", wraps=__import__) as imports:
                ready,vectors=sfx_map_job.load_vectors([Path("cached.wav")])
            self.assertEqual(len(ready),1)
            self.assertEqual(vectors.shape,(1,8))
            self.assertFalse(any(c.args[0]=="mtag.encoders" for c in imports.call_args_list))

    def test_four_file_layout_is_valid(self):
        from threadpoolctl import threadpool_limits
        with threadpool_limits(limits=2):
            plane=sfxmap.reduce_to_plane(np.eye(4,dtype=np.float32))
        self.assertEqual(plane.shape,(4,2))
        self.assertTrue(np.isfinite(plane).all())

    def test_plane_keeps_clusters_apart(self):
        X, truth = blobs()
        plane = sfxmap.reduce_to_plane(X)
        self.assertLessEqual(np.abs(plane).max(), 1.0001)
        d = ((plane[:, None] - plane[None]) ** 2).sum(-1)
        np.fill_diagonal(d, np.inf)
        self.assertTrue((truth[d.argmin(1)] == truth).all())

    def test_nearest_is_closest_first_and_never_itself(self):
        X, truth = blobs()
        nn = sfxmap.nearest(X, k=5, block=7)
        self.assertEqual(nn.shape, (len(X), 5))
        self.assertFalse((nn == np.arange(len(X))[:, None]).any())
        self.assertTrue((truth[nn] == truth[:, None]).all())
        U = sfxmap.unit(X)
        sims = np.take_along_axis(U @ U.T, nn, axis=1)
        self.assertTrue((np.diff(sims, axis=1) <= 1e-6).all())

    def test_groups_follow_the_sound(self):
        X, truth = blobs(n_per=10, groups=4)
        G = sfxmap.group(X, size=10)
        self.assertEqual(len(set(G.tolist())), 4)
        for g in range(4):
            self.assertEqual(len(set(truth[G == g].tolist())), 1)

    def test_filename_words(self):
        self.assertEqual(sfxmap.name_tokens("Play_Amb_Lp_02"), set())
        self.assertEqual(sfxmap.name_tokens("sfx_npc_03b"), set())
        self.assertEqual(sfxmap.name_tokens("WhooshFast 03"), {"whoosh", "fast"})
        self.assertEqual(sfxmap.name_tokens("BabyCryWhimper"), {"baby", "cry", "whimper"})

    def test_names_come_from_agreeing_words_else_audio(self):
        paths = ["Whoosh 1.wav", "Whoosh 2.wav", "WhooshFast.wav", "sfx_0004.wav",
                 "sfx_0005.wav", "sfx_0006.wav"]
        groups = np.array([0, 0, 0, 1, 1, 1])
        audio = np.array([[1, 0]] * 3 + [[0, 1]] * 3, dtype=np.float32)
        text = np.array([[1, 0], [0, 1]], dtype=np.float32)
        names = sfxmap.name_groups(paths, groups, audio, text, phrases=["a whoosh", "a thud"])
        self.assertEqual(names, ["Whoosh", "thud"])

    def test_names_are_unique(self):
        groups = np.array([0, 0, 1, 1])
        audio = np.array([[1, 0], [1, 0], [1, 0.1], [1, 0.1]], dtype=np.float32)
        text = np.array([[1, 0], [0.9, 0.4]], dtype=np.float32)
        names = sfxmap.name_groups(["a", "b", "c", "d"], groups, audio, text, phrases=["a thud", "a pop"])
        self.assertEqual(len(set(names)), 2)

    def test_renamed_files_get_the_same_map(self):
        X, _ = blobs()
        a = sfx_map_job.build([Path(f"Real Name {i}.wav") for i in range(len(X))], X, None)
        b = sfx_map_job.build([Path(f"sfx_{i:04d}.wav") for i in range(len(X))], X, None)
        self.assertEqual(a["group"], b["group"])
        self.assertEqual(a["nn"], b["nn"])
        self.assertEqual(list(a["points"].values()), list(b["points"].values()))

    def test_write_keeps_the_previous_map_and_up_to_date(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "sfx-soundmap.json"
            out.write_text('{"version": 1}', encoding="utf-8")
            X, _ = blobs(n_per=3, groups=2)
            paths = [Path(f"{i}.wav") for i in range(len(X))]
            with patch.object(sfx_map_job, "_space", return_value="test-space"):
                data = sfx_map_job.build(paths, X, None)
                sfx_map_job.write(out, data)
                self.assertEqual(json.loads(sfx_map_job.prev_path(out).read_text(encoding="utf-8")), {"version": 1})
                self.assertTrue(sfx_map_job.up_to_date(out, paths))
                self.assertFalse(sfx_map_job.up_to_date(out, paths[:-1]))
            doc = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(len(doc["nn"]), len(paths))
            self.assertEqual(sorted(r["count"] for r in doc["regions"])[-1], max(np.bincount(doc["group"])))


if __name__=="__main__":unittest.main()
