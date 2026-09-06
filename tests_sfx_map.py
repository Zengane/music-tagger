import unittest
from pathlib import Path
from unittest.mock import patch
import numpy as np
import sfx_map_job

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
        from map_job import reduce_to_plane
        from threadpoolctl import threadpool_limits
        with threadpool_limits(limits=2):
            plane=reduce_to_plane(np.eye(4,dtype=np.float32))
        self.assertEqual(plane.shape,(4,2))
        self.assertTrue(np.isfinite(plane).all())
if __name__=="__main__":unittest.main()
