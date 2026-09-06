"""Focused CPU-only regressions for the tagging job's cache fast path."""
import builtins
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np
import tag_job
from mtag.dataset import EmbeddingCache
from mtag.model import Tagger


class CachedJobTests(unittest.TestCase):
    def run_job(self, cache_get):
        events = []
        model = SimpleNamespace(encoder_name="fusion", probes={}, zeroshot={},
                                suggest=lambda vector: {"selected": [], "scores": {}})
        original_import = builtins.__import__
        def forbid_models(name, *args, **kwargs):
            if name == "torch" or name.startswith("mtag.encoders"):
                raise AssertionError("cached tagging attempted to load an encoder")
            return original_import(name, *args, **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            paths = Path(directory) / "paths.txt"
            paths.write_text("one.mp3\ntwo.mp3\none.mp3\n", encoding="utf-8")
            with patch.object(Tagger, "load", return_value=model), \
                 patch.object(EmbeddingCache, "get", side_effect=cache_get), \
                 patch.object(tag_job, "emit", side_effect=lambda **data: events.append(data)), \
                 patch.object(tag_job.console, "init"), \
                 patch("mtag.model.MODEL_PATH"), \
                 patch("sys.argv", ["tag_job.py", "--paths-from", str(paths)]), \
                 patch("builtins.__import__", side_effect=forbid_models):
                result = tag_job.main()
        return result, events

    def test_cached_paths_skip_models_and_deduplicate(self):
        result, events = self.run_job(lambda path: np.zeros(4))
        self.assertEqual(result, 0)
        self.assertEqual([e["count"] for e in events if e["event"] == "total"], [2])
        self.assertEqual(sum(e["event"] == "result" for e in events), 2)
        self.assertEqual(events[-1], {"event": "done", "analyzed": 2, "failed": 0})

    def test_bad_file_does_not_abort_cached_batch(self):
        def get(path):
            if str(path) == "one.mp3":
                raise FileNotFoundError("fixture unavailable")
            return np.zeros(4)
        result, events = self.run_job(get)
        self.assertEqual(result, 0)
        self.assertEqual(events[-1], {"event": "done", "analyzed": 1, "failed": 1})
        self.assertTrue(any(e["event"] == "error" and e["path"] == "one.mp3" for e in events))


if __name__ == "__main__":
    unittest.main()
