"""Which profile a machine gets, and that choosing one needs no torch.

A fake nvidia-smi on PATH stands in for each graphics card.

    python tests_profiles.py
"""

import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

import mtag.profiles as P


def fake_smi(folder: Path, line: str) -> None:
    if os.name == "nt":
        (folder / "nvidia-smi.bat").write_text(f"@echo {line}\n")
    else:
        f = folder / "nvidia-smi"
        f.write_text(f"#!/bin/sh\necho '{line}'\n")
        f.chmod(f.stat().st_mode | stat.S_IEXEC)


class Profiles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.environ.get("PATH", "")
        self.env = {k: os.environ.get(k) for k in ("MUSICTAGGER_PROFILE", "MUSICTAGGER_MODEL_SIZE")}
        for k in self.env:
            os.environ.pop(k, None)
        P._DETECTED = None

    def tearDown(self):
        os.environ["PATH"] = self.path
        for k, v in self.env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        P._DETECTED = None
        self.tmp.cleanup()

    def with_card(self, line):
        d = Path(self.tmp.name)
        fake_smi(d, line)
        os.environ["PATH"] = str(d) + os.pathsep + self.path
        P._DETECTED = None

    @unittest.skipIf(sys.platform == "darwin", "Macs are judged by their chip, not nvidia-smi")
    def test_cards(self):
        for line, want in (("NVIDIA GeForce RTX 3070 Ti, 8192", "best"),
                           ("NVIDIA GeForce GTX 1650, 4096", "balanced"),
                           ("NVIDIA GeForce GT 1030, 2048", "fast")):
            self.with_card(line)
            hw = P.detect()
            self.assertEqual(hw.device, "cuda", line)
            self.assertEqual(P.recommend(hw), want, line)
            self.assertEqual(P.profile_name(), want)

    def test_an_explicit_choice_wins(self):
        os.environ["MUSICTAGGER_PROFILE"] = "fast"
        self.assertEqual(P.profile_name(), "fast")
        os.environ["MUSICTAGGER_PROFILE"] = "large"  # the older name
        self.assertEqual(P.profile_name(), "best")

    def test_every_profile_names_its_sound_cache(self):
        for p in P.PROFILES.values():
            self.assertTrue(P.audio_text_space(p))

    def test_choosing_does_not_load_torch(self):
        import subprocess

        code = "import sys, mtag.profiles as P; P.profile_name(); print('torch' in sys.modules)"
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                             cwd=str(Path(__file__).resolve().parent))
        self.assertEqual(out.stdout.strip(), "False", out.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
