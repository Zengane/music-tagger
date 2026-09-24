"""The measured half of media analysis, on files made here by ffmpeg.

No model is needed for any of this: green screens, alpha, black backgrounds,
flashes, loops and cuts are all in the pixels. Each test builds a file that is
unambiguously one thing and checks it is recognised as that thing, and that
the neighbouring tags do not fire on it.

    python tests_media.py
"""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import numpy as np

from mtag import kinds as K
from mtag.media import decode as D
from mtag.media import measure as M

FFMPEG = shutil.which("ffmpeg")


def ff(*args):
    subprocess.run([FFMPEG, "-v", "error", "-y", *args], check=True)


def tags_of(path: Path, kind: str) -> dict:
    visual = D.load_visual(path, kind)
    return M.measure(visual, kind).tags


@unittest.skipUnless(FFMPEG, "ffmpeg is needed to build the test media")
class MeasuredTags(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.dir = Path(cls.tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def path(self, name):
        return self.dir / name

    # ── stills ──────────────────────────────────────────────────────────────

    def test_green_screen_still(self):
        from PIL import Image, ImageDraw

        img = Image.new("RGB", (640, 360), (20, 190, 60))
        ImageDraw.Draw(img).ellipse((250, 90, 390, 330), fill=(200, 160, 130))
        p = self.path("person_on_green.jpg")
        img.save(p, quality=90)
        tags = tags_of(p, K.IMAGE)
        self.assertIn("Green-Screen", tags)
        self.assertNotIn("Blue-Screen", tags)
        self.assertNotIn("Black-Background", tags)

    def test_blue_screen_still(self):
        from PIL import Image, ImageDraw

        img = Image.new("RGB", (640, 360), (20, 60, 210))
        ImageDraw.Draw(img).rectangle((260, 100, 380, 330), fill=(180, 140, 120))
        p = self.path("blue.png")
        img.save(p)
        tags = tags_of(p, K.IMAGE)
        self.assertIn("Blue-Screen", tags)
        self.assertNotIn("Green-Screen", tags)

    def test_png_with_alpha(self):
        from PIL import Image, ImageDraw

        img = Image.new("RGBA", (400, 400), (0, 0, 0, 0))
        ImageDraw.Draw(img).ellipse((100, 100, 300, 300), fill=(255, 120, 0, 255))
        p = self.path("sticker.png")
        img.save(p)
        tags = tags_of(p, K.IMAGE)
        self.assertIn("Alpha-Channel", tags)
        # The transparent area is not a black background.
        self.assertNotIn("Black-Background", tags)
        self.assertIn("Orange", tags)

    def test_opaque_rgba_png_is_not_transparent(self):
        from PIL import Image

        img = Image.new("RGBA", (200, 200), (90, 120, 200, 255))
        p = self.path("opaque_rgba.png")
        img.save(p)
        self.assertNotIn("Alpha-Channel", tags_of(p, K.IMAGE))

    def test_isolated_on_white(self):
        from PIL import Image, ImageDraw

        img = Image.new("RGB", (600, 600), (255, 255, 255))
        ImageDraw.Draw(img).rectangle((200, 150, 400, 450), fill=(200, 30, 30))
        p = self.path("product.jpg")
        img.save(p, quality=95)
        tags = tags_of(p, K.IMAGE)
        self.assertIn("White-Background", tags)
        self.assertIn("Red", tags)

    def test_black_and_white_photo(self):
        rng = np.random.default_rng(1)
        grey = (rng.random((300, 400)) * 200 + 30).astype(np.uint8)
        from PIL import Image

        p = self.path("bw.png")
        Image.fromarray(np.stack([grey] * 3, -1)).save(p)
        tags = tags_of(p, K.IMAGE)
        self.assertIn("Black-and-White", tags)
        self.assertNotIn("Colourful", tags)

    def test_vertical_still(self):
        from PIL import Image

        p = self.path("story.png")
        Image.new("RGB", (1080, 1920), (120, 80, 60)).save(p)
        self.assertIn("Vertical", tags_of(p, K.IMAGE))

    # ── video ───────────────────────────────────────────────────────────────

    def test_muzzle_flash_on_black(self):
        # Two frames of bright orange in a second of black: a muzzle flash
        # element, meant for a Screen blend.
        p = self.path("muzzle_flash.mov")
        ff("-f", "lavfi", "-i", "color=c=black:s=640x360:r=24:d=2",
           "-vf", "drawbox=x=250:y=130:w=140:h=100:color=0xFFB040@1:t=fill:enable='between(t,0.5,0.58)'",
           "-c:v", "libx264", "-pix_fmt", "yuv420p", str(p))
        v = D.load_visual(p, K.VIDEO)
        m = M.measure(v, K.VIDEO)
        self.assertIn("Black-Background", m.tags)
        self.assertIn("Flash", m.tags, m.metrics)
        self.assertTrue(m.metrics.get("short_flash"), m.metrics.get("flashes"))
        self.assertIn("Short-Element", m.tags)
        self.assertNotIn("Green-Screen", m.tags)

    def test_explosion_decays_slowly(self):
        # Bright, then fading over about a second: the shape of an explosion.
        p = self.path("explosion.mp4")
        ff("-f", "lavfi", "-i", "color=c=black:s=640x360:r=24:d=3",
           "-vf", "geq=r='255*if(gt(T,0.5),exp(-(T-0.5)*1.2),0)':g='150*if(gt(T,0.5),exp(-(T-0.5)*1.2),0)':b='40*if(gt(T,0.5),exp(-(T-0.5)*1.2),0)'",
           "-c:v", "libx264", "-pix_fmt", "yuv420p", str(p))
        m = M.measure(D.load_visual(p, K.VIDEO), K.VIDEO)
        self.assertIn("Flash", m.tags, m.metrics)
        self.assertTrue(m.metrics.get("long_flash"), m.metrics.get("flashes"))

    def test_green_screen_video(self):
        p = self.path("green_plate.mp4")
        ff("-f", "lavfi", "-i", "color=c=0x14C83C:s=640x360:r=25:d=2",
           "-vf", "drawbox=x='100+t*100':y=100:w=120:h=200:color=0xC8A080@1:t=fill",
           "-c:v", "libx264", "-pix_fmt", "yuv420p", str(p))
        tags = tags_of(p, K.VIDEO)
        self.assertIn("Green-Screen", tags)

    def test_prores_4444_alpha(self):
        p = self.path("overlay_alpha.mov")
        ff("-f", "lavfi", "-i", "color=c=white@0.0:s=320x180:r=24:d=1,format=rgba",
           "-vf", "drawbox=x=100:y=50:w=80:h=80:color=0xFF3030@1:t=fill",
           "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", str(p))
        v = D.load_visual(p, K.VIDEO)
        self.assertTrue(v.probe.has_alpha, v.probe.pix_fmt)
        self.assertIn("Alpha-Channel", M.measure(v, K.VIDEO).tags)

    def test_loop(self):
        # A hue cycle that ends where it began.
        p = self.path("loop.mp4")
        ff("-f", "lavfi", "-i", "testsrc2=s=320x180:r=25:d=2",
           "-vf", "hue=h=t*180", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(p))
        # testsrc2 has a moving counter, so compare a genuinely cyclic source:
        q = self.path("loop2.mp4")
        ff("-f", "lavfi", "-i", "color=c=0x3060C0:s=320x180:r=25:d=2",
           "-vf", "hue=h=t*180:s=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(q))
        m = M.measure(D.load_visual(q, K.VIDEO), K.VIDEO)
        self.assertIn("Loop", m.tags, m.metrics.get("loop_distance"))

    def test_not_a_loop(self):
        p = self.path("ramp.mp4")
        ff("-f", "lavfi", "-i", "color=c=black:s=320x180:r=25:d=3",
           "-vf", "geq=r='255*T/3':g='200*T/3':b='90'", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(p))
        self.assertNotIn("Loop", tags_of(p, K.VIDEO))

    def test_cuts_and_single_shot(self):
        # Six genuinely different pictures, one after another.
        sources = ("testsrc2", "mandelbrot", "smptebars", "rgbtestsrc", "life=mold=10:r=25:ratio=0.3", "cellauto=rule=110")
        parts = []
        for i, src in enumerate(sources):
            q = self.path(f"shot{i}.mp4")
            spec = src if "=" in src else f"{src}=s=320x180:r=25"
            ff("-f", "lavfi", "-i", spec, "-t", "1.5", "-vf", "scale=320:180,fps=25,format=yuv420p",
               "-c:v", "libx264", str(q))
            parts.append(q)
        listing = self.path("parts.txt")
        listing.write_text("".join(f"file '{q}'\n" for q in parts))
        montage = self.path("montage.mp4")
        ff("-f", "concat", "-safe", "0", "-i", str(listing), "-c", "copy", str(montage))
        m = M.measure(D.load_visual(montage, K.VIDEO), K.VIDEO)
        self.assertGreaterEqual(m.metrics["cuts"], 4, m.metrics)
        self.assertLessEqual(m.metrics["cuts"], 6, m.metrics)
        self.assertNotIn("Single-Shot", m.tags)

        single = self.path("single.mp4")
        ff("-f", "lavfi", "-i", "testsrc2=s=320x180:r=25:d=4", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(single))
        m2 = M.measure(D.load_visual(single, K.VIDEO), K.VIDEO)
        self.assertEqual(m2.metrics["cuts"], 0, m2.metrics)
        self.assertIn("Single-Shot", m2.tags)

    def test_vertical_high_frame_rate(self):
        p = self.path("slowmo_vertical.mp4")
        ff("-f", "lavfi", "-i", "testsrc2=s=360x640:r=120:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(p))
        tags = tags_of(p, K.VIDEO)
        self.assertIn("Vertical", tags)
        self.assertIn("High-Frame-Rate", tags)

    def test_fade_in(self):
        p = self.path("fade.mp4")
        ff("-f", "lavfi", "-i", "testsrc2=s=320x180:r=25:d=3", "-vf", "fade=t=in:st=0:d=1.5",
           "-c:v", "libx264", "-pix_fmt", "yuv420p", str(p))
        self.assertIn("Fade-In", tags_of(p, K.VIDEO))

    # ── documents ───────────────────────────────────────────────────────────

    def test_text_documents(self):
        p = self.path("notes.txt")
        p.write_text("Shot list\nOpening drone shot of the harbour at dawn.", encoding="utf-8")
        self.assertIn("harbour", D.read_text(p))

        srt = self.path("captions.srt")
        srt.write_text("1\n00:00:01,000 --> 00:00:02,000\nHello <i>there</i>\n\n2\n00:00:03,000 --> 00:00:04,000\nGeneral Kenobi\n")
        text = D.read_text(srt)
        self.assertEqual(text.splitlines(), ["Hello there", "General Kenobi"])

    def test_docx(self):
        import docx

        d = docx.Document()
        d.add_paragraph("Invoice number 42")
        d.add_paragraph("Total due: 300 EUR")
        p = self.path("invoice.docx")
        d.save(str(p))
        self.assertIn("Total due", D.read_text(p))

    def test_pdf_text_and_page(self):
        # Pillow writes a one-page PDF with no text layer; pypdfium2 must
        # still render it for a thumbnail.
        from PIL import Image

        p = self.path("scan.pdf")
        Image.new("RGB", (300, 400), (240, 230, 200)).save(p)
        v = D.load_visual(p, K.DOCUMENT)
        self.assertEqual(len(v.frames), 1)
        self.assertEqual(D.read_text(p).strip(), "")

    def test_kinds(self):
        self.assertEqual(K.kind_of("a/b/C.MP4"), K.VIDEO)
        self.assertEqual(K.kind_of("x.glb"), K.MODEL)
        self.assertEqual(K.kind_of("x.wav"), K.AUDIO)
        self.assertEqual(K.kind_of("x.pdf"), K.DOCUMENT)
        self.assertIsNone(K.kind_of("x.exe"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
